defmodule CompassAdmin.Services.ExportMetrics do
  @num_partitions 40
  @batch_size 10000
  @max_timeout 15_000
  @lock_exp_sec 30
  @report_index "compass_metric_model_activity"
  @config Application.get_env(:compass_admin, __MODULE__, %{})
  require Logger

  alias CompassAdmin.Repo
  alias CompassAdmin.User
  alias CompassAdmin.LabModel

  alias Metrics.CompassInstrumenter
  import Ecto.Query

  def with_lock(func_sym) do
    key = to_string(func_sym)
    case Redlock.lock(key, @lock_exp_sec) do
      {:ok, mutex} ->
        try do
          :erlang.apply(__MODULE__, func_sym, [])
        after
          Redlock.unlock(key, mutex)
        end

      :error ->
        Logger.error "failed to lock resource. maybe redis connection got trouble."
        {:error, :system_error}
    end
  end

  def start() do
    IO.puts("exporting metrics ...")
    Enum.each([gitee: :raw, github: :raw, gitee: :enriched, github: :enriched], fn {origin, type} ->
      with {:ok, %{aggregations: %{"distinct" => %{value: value}}}} <-
      Snap.Search.search(
        CompassAdmin.Cluster,
        "#{origin}-repo_#{type}",
        %{
          size: 0,
          aggs: %{distinct: %{cardinality: %{field: :origin}}}
        }
      ) do
        CompassInstrumenter.observe(:report_stats, value, [origin, type, :repo])
      end
    end)

    Enum.flat_map(0..(@num_partitions - 1), fn partition ->
      with {:ok, %{aggregations: %{"distinct_values" => %{buckets: buckets}}}} <-
      Snap.Search.search(
        CompassAdmin.Cluster,
        @report_index,
        %{
          size: 0,
          aggs: %{
            distinct_values: %{
              terms: %{
                field: "label.keyword",
                size: @batch_size,
                include: %{
                  partition: partition,
                  num_partitions: @num_partitions
                },
                order: %{_term: :asc}
              }
            }
          }
        }
      ) do
        Enum.map(buckets, & &1["key"])
      end
    end)
    |> Enum.group_by(fn label ->
      if is_url?(label) do
        if String.contains?(label, "gitee.com"), do: "gitee", else: "github"
      else
        "community"
      end
    end)
    |> Enum.map(fn {origin, list} ->
      value = length(list)

      CompassInstrumenter.observe(:report_stats, value, [
            origin,
            :finished,
            if(origin == "community", do: origin, else: :repo)
          ])

      {origin, value}
    end)

    CompassInstrumenter.observe(:token_stats, length(@config[:github_tokens]), [:count])

    token_stats =
      @config[:github_tokens]
      |> Enum.with_index()
      |> Enum.chunk_every(4)
      |> Enum.map(fn tokens_with_index ->
      Enum.map(tokens_with_index, fn {token, index} ->
        Task.async(fn ->
          case Finch.build(
                :get,
                "https://api.github.com/rate_limit",
                [{"Content-Type", "application/json"}, {"Authorization", "Bearer #{token}"}],
                nil,
                proxy: @config[:proxy]
              )
              |> Finch.request(CompassFinch) do
            {:ok, %{body: body}} ->
              case Jason.decode(body) do
                {:ok,
                 %{
                   "rate" => %{
                     "limit" => limit,
                     "remaining" => remaining,
                     "reset" => reset,
                     "used" => used
                   }
                 }} ->
                  CompassInstrumenter.observe(:target_token, limit, ["token-#{index}", :limit])
                  CompassInstrumenter.observe(:target_token, remaining, ["token-#{index}", :remaining])
                  CompassInstrumenter.observe(:target_token, used, ["token-#{index}", :used])
                  CompassInstrumenter.observe(:target_token, reset, ["token-#{index}", :reset])
                  {limit, remaining, used, reset}

                _ ->
                  {0, 0, 0, 0}
              end

            _ ->
              {0, 0, 0, 0}
          end
        end)
      end)
      |> Task.await_many(@max_timeout)
    end)

      token_stats = List.flatten(token_stats)

      token_sum = Enum.sum(Enum.map(token_stats, &elem(&1, 0)))
      token_remaining = Enum.sum(Enum.map(token_stats, &elem(&1, 1)))
      token_used = Enum.sum(Enum.map(token_stats, &elem(&1, 2)))
      CompassInstrumenter.observe(:token_stats, token_sum, [:sum])
      CompassInstrumenter.observe(:token_stats, token_remaining, [:remaining])
      CompassInstrumenter.observe(:token_stats, token_used, [:used])

      CompassInstrumenter.observe(:token_stats, token_used / (token_sum + 1), [
        :used_percentage
      ])

      # tasks queue status
      {:ok, channel} = AMQP.Application.get_channel(:compass_chan)
      Enum.each(@config[:all_queues], fn [name: name, desc: desc] ->
        {:ok, queue} = AMQP.Queue.declare(channel, name, [durable: true])
        message_count = queue.message_count
        CompassInstrumenter.observe(:task_stats, message_count, [desc])
      end)
  end

  defp is_url?(str) do
    case URI.parse(str) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and not is_nil(host) ->
        true

      _ ->
        false
    end
  end

  def weekly() do
    IO.puts("exporting weekly changes ...")
    now = Timex.now()
    begin_date = now |> Timex.shift(days: -7) |> Timex.to_date |> Date.to_string
    end_date = now |> Timex.to_date |> Date.to_string
    git_commit_snapshot(begin_date, end_date, :last_week)
    metadata_updated_snapshot("now-7d", "now", :last_week)
    rawdata_updated_snapshot("now-7d", "now", :last_week)
    user_stat_snapshot()
    lab_model_stat_snapshot()
  end

  def monthly() do
    IO.puts("exporting monthly changes ...")
    now = Timex.now()
    begin_date = now |> Timex.shift(days: -30) |> Timex.to_date |> Date.to_string
    end_date = now |> Timex.to_date |> Date.to_string
    git_commit_snapshot(begin_date, end_date, :last_month)
    metadata_updated_snapshot("now-30d", "now", :last_month)
    rawdata_updated_snapshot("now-30d", "now", :last_month)
  end

  # src shell:
  # git log --grep='^Update at' -p -1 | grep '^commit' | awk '{print $2, "all_repositories.csv"}' | xargs git show | grep '^[+|-]'
  def git_commit_snapshot(begin_date, end_date, panel) do
    cd_repo = "cd #{@config[:projects_information_path]}"
    csv_file = "all_repositories.csv"
    snapshot =
      with {_fetch, 0} <- System.shell("#{cd_repo}; export HTTPS_PROXY=#{@config[:proxy]}; git pull;"),
           {commits, 0} <- System.shell("#{cd_repo}; git log --grep='^Update at' --since=#{begin_date} --until=#{end_date} | grep '^commit'") do

        String.split(commits, "\n")
        |> Enum.reduce(
          %{
            total_inc: 0, total_dec: 0,
            gitee_inc: 0, github_inc: 0,
            gitee_dec: 0, github_dec: 0,
            community_inc: 0, community_dec: 0
          },
        fn commit, result ->
          with {output, 0} <- System.shell("#{cd_repo}; git show #{String.split(commit, " ") |> List.last() |> String.trim_trailing()} #{csv_file} | grep '^[+|-]'") do
            String.split(output, "\n")
            |> Enum.reduce(
              result,
            fn row, acc ->
              case row do
                "+++" <> _ -> acc
                "---" <> _ -> acc
                "+" <> label ->
                  case URI.parse(label) do
                    %{host: "github.com"} ->
                      %{acc| total_inc: acc[:total_inc] + 1, github_inc: acc[:github_inc] + 1}
                    %{host: "gitee.com"} ->
                      %{acc| total_inc: acc[:total_inc] + 1, gitee_inc: acc[:gitee_inc] + 1}
                    _ ->
                      %{acc| total_inc: acc[:total_inc] + 1, community_inc: acc[:community_inc] + 1}
                  end
                "-" <> label ->
                  case URI.parse(label) do
                    %{host: "github.com"} ->
                      %{acc| total_dec: acc[:total_dec] + 1, github_dec: acc[:github_dec] + 1}
                    %{host: "gitee.com"} ->
                      %{acc| total_dec: acc[:total_dec] + 1, gitee_dec: acc[:gitee_dec] + 1}
                    _ ->
                      %{acc| total_dec: acc[:total_dec] + 1, community_dec: acc[:community_dec] + 1}
                  end
                _ ->
                  acc
              end
            end)
          else
            _ -> result
          end
        end)
      end
    case snapshot do
      {output, error_code} ->
        IO.puts("No Changes, #{output}, error_code: #{error_code}")
      _ ->
        Enum.map(snapshot, fn {origin, value} ->
          {action, origin, level} =
            case origin do
              :total_inc -> {:created, :all, :all}
              :total_dec -> {:deleted, :all, :all}
              :gitee_inc -> {:created, :gitee, :repo}
              :github_inc -> {:created, :github, :repo}
              :gitee_dec -> {:deleted, :gitee, :repo}
              :github_dec -> {:deleted, :github, :repo}
              :community_inc -> {:created, :community, :community}
              :community_dec -> {:deleted, :community, :community}
            end
          CompassInstrumenter.observe(:report_changes, value, [action, origin, level, panel])
        end)
    end
  end

  def rawdata_updated_snapshot(begin_date, end_date, panel) do
    Enum.map(
      [
        {:commits, :gitee, "gitee-git_raw"},
        {:commits, :github, "github-git_raw"},
        {:issues, :gitee, "gitee-issues_raw"},
        {:issues, :github, "github-issues_raw"},
        {:pulls, :gitee, "gitee-pulls_raw"},
        {:pulls, :github, "github-pulls_raw"},
        {:issue_comments, :gitee, "gitee2-issues_enriched"},
        {:issue_comments, :github, "github2-issues_enriched"},
        {:pull_comments, :gitee, "gitee2-pulls_enriched"},
        {:pull_comments, :github, "github2-pulls_enriched"}
      ],
      fn {type, origin, index} ->
        with {:ok, %{"count" => count}} = CompassAdmin.Cluster.post("/#{index}/_count", rawdata_updated_query(begin_date, end_date)) do
          CompassInstrumenter.observe(:metadata_changes, count, [origin, type, panel])
        end
      end)
  end

  def metadata_updated_snapshot(begin_date, end_date, panel) do
    total =
      Enum.map(
        [{:repo, :gitee}, {:repo, :github}, {:community, :community}],
        fn {level, origin} ->
          with {:ok, %{aggregations: %{"distinct_labels" => %{value: value}}}} <- Snap.Search.search(
                 CompassAdmin.Cluster, @report_index, metadata_updated_query(level, origin, begin_date, end_date)
               ) do
            CompassInstrumenter.observe(:report_changes, value, [:updated, origin, level, panel])
            value
          else
            _ -> 0
          end
        end)
        |> Enum.sum()
    CompassInstrumenter.observe(:report_changes, total, [:updated, :all, :all, panel])
  end

  def metadata_updated_query(level, origin, begin_date, end_date) do
    prefix =
      case origin do
        :gitee -> "https://gitee.com"
        :github -> "https://github.com"
        _ -> nil
      end
    range = %{range: %{metadata__enriched_on: %{gte: begin_date, lt: end_date}}}
    level = %{match: %{"level.keyword" => level}}
    phrase = if prefix, do: %{match_phrase: %{label: prefix}}, else: nil

    %{
      query: %{
        bool: %{
          must: Enum.filter([range, level, phrase], &(&1))
        }
      },
      size: 0,
      aggs: %{
        distinct_labels: %{
          cardinality: %{
            field: "label.keyword"
          }
        }
      }
    }
  end

  def rawdata_updated_query(begin_date, end_date) do
    %{
      query: %{
        bool: %{
          filter: [
            %{
              range: %{
                metadata__updated_on: %{
                  gte: begin_date,
                  lte: end_date
                }
              }
            }
          ]
        }
      }
    }
  end

  def user_stat_snapshot() do
    user_count = Repo.one(from(u in User, select: count("*")))
    CompassInstrumenter.observe(:user_stats, user_count, [:count])
  end

  def lab_model_stat_snapshot() do
    lab_model_count = Repo.one(from(m in LabModel, select: count("*")))
    CompassInstrumenter.observe(:lab_model_stats, lab_model_count, [:count])
    private_lab_model_count = Repo.one(from(m in LabModel, select: count("*"), where: m.is_public == false))
    CompassInstrumenter.observe(:lab_model_stats, private_lab_model_count, [:private_count])
  end
end
