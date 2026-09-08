defmodule Throttle.DispatchConcurrencyTest do
  # Real committed transactions on distinct pool connections, not shared
  # sandbox transactions. Cleanup targets only this test's random identities.
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Throttle.{Admission, DispatchStore, Repo, OAuthManager, HTTPStub}
  alias Throttle.Schemas.{ActionExecution, SecureOAuthToken}

  defp committed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  setup do
    portal = 8_000_000_000 + System.unique_integer([:positive])
    queue = "queue:#{portal}:902:903:0"
    callback = "concurrency-#{portal}"

    attrs = %{
      queue_id: queue,
      callback_id: callback,
      max_throughput: "1",
      time: "1",
      period: "days",
      expires_at: Throttle.BlockExpiration.expires_at()
    }

    on_exit(fn ->
      committed(fn ->
        Repo.delete_all(from a in ActionExecution, where: a.queue_id == ^queue)
        Repo.query!("DELETE FROM dispatch_queues WHERE queue_id=$1", [queue])
        Repo.query!("DELETE FROM dispatch_portals WHERE portal_id=$1", [portal])
        Repo.delete_all(from t in SecureOAuthToken, where: t.portal_id == ^portal)
      end)
    end)

    %{portal: portal, queue: queue, attrs: attrs}
  end

  test "concurrent refreshes reuse the committed token across connections", %{portal: portal} do
    previous = Application.get_env(:throttle, :http_adapter)
    Application.put_env(:throttle, :http_adapter, HTTPStub)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:throttle, :http_adapter, previous),
        else: Application.delete_env(:throttle, :http_adapter)
    end)

    responses = [
      HTTPStub.response(
        200,
        Jason.encode!(%{
          access_token: "new-fake-access",
          refresh_token: "new-fake-refresh",
          expires_in: 3600
        })
      )
    ]

    start_supervised!(%{id: HTTPStub, start: {HTTPStub, :start_link, [responses]}})

    committed(fn ->
      %SecureOAuthToken{}
      |> SecureOAuthToken.changeset(%{
        portal_id: portal,
        access_token: "old-fake-access",
        refresh_token: "old-fake-refresh",
        token_response: %{"hub_id" => portal},
        expires_at: DateTime.add(DateTime.utc_now(), -1)
      })
      |> Repo.insert!()
    end)

    results =
      1..20
      |> Task.async_stream(
        fn _ ->
          committed(fn -> OAuthManager.get_token(portal) end)
        end,
        max_concurrency: 10,
        timeout: 15_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, fn result ->
             match?({:ok, {:ok, %{access_token: "new-fake-access"}}}, result)
           end)

    committed(fn ->
      assert {:ok, %{access_token: "new-fake-access"}} =
               OAuthManager.force_refresh_token(portal, "old-fake-access")
    end)

    assert length(HTTPStub.requests()) == 1
  end

  test "concurrent webhook retries commit one identity", %{attrs: attrs} do
    results =
      1..20
      |> Task.async_stream(fn _ -> committed(fn -> Admission.admit(attrs) end) end,
        max_concurrency: 10,
        timeout: 15_000
      )
      |> Enum.to_list()

    ids = for {:ok, {:ok, action}} <- results, do: action.id
    assert length(ids) == 20
    assert length(Enum.uniq(ids)) == 1
  end

  test "unchanged-rate admission does not wait for a dispatcher queue lock", %{
    attrs: attrs,
    queue: queue
  } do
    committed(fn -> assert {:ok, _} = Admission.admit(attrs) end)
    parent = self()

    locker =
      Task.async(fn ->
        committed(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT queue_id FROM dispatch_queues WHERE queue_id=$1 FOR UPDATE", [
              queue
            ])

            send(parent, :queue_locked)
            receive do: (:release -> :ok)
          end)
        end)
      end)

    assert_receive :queue_locked, 5_000

    admission =
      Task.async(fn ->
        committed(fn -> Admission.admit(%{attrs | callback_id: "#{attrs.callback_id}-new"}) end)
      end)

    # Always release the separate connection, including when the assertion fails.
    result = Task.yield(admission, 1_000)
    send(locker.pid, :release)
    Task.await(locker)
    if is_nil(result), do: Task.await(admission)
    assert {:ok, {:ok, _}} = result
  end

  test "an aborted admission transaction returns retryable HTTP and can be replayed", %{
    attrs: attrs,
    portal: portal
  } do
    committed(fn -> assert {:ok, _} = Admission.admit(attrs) end)
    handler = "abort-admission-#{portal}"

    :ok =
      :telemetry.attach(handler, [:throttle, :repo, :query], &__MODULE__.abort_after_read/4, nil)

    on_exit(fn -> :telemetry.detach(handler) end)
    callback = "#{attrs.callback_id}-aborted"

    params = %{
      "callbackId" => callback,
      "origin" => %{"portalId" => portal, "actionDefinitionId" => 903},
      "context" => %{"workflowId" => 902},
      "inputFields" => %{"maxThroughPut" => "1", "time" => "1", "period" => "days"}
    }

    committed(fn ->
      Process.put(:abort_admission_after_read, true)
      conn = ThrottleWeb.HubSpotController.handle_action(Phoenix.ConnTest.build_conn(), params)

      assert %{"error" => "Throttler temporarily unavailable"} =
               Phoenix.ConnTest.json_response(conn, 503)

      assert Plug.Conn.get_resp_header(conn, "retry-after") == ["30"]
      assert Repo.get_by(ActionExecution, callback_id: callback) == nil

      conn = ThrottleWeb.HubSpotController.handle_action(Phoenix.ConnTest.build_conn(), params)

      assert %{"outputFields" => %{"hs_execution_state" => "BLOCK"}} =
               Phoenix.ConnTest.json_response(conn, 200)

      assert Repo.aggregate(from(a in ActionExecution, where: a.callback_id == ^callback), :count) ==
               1
    end)
  end

  def abort_after_read(_event, _measurements, %{query: query}, _config) do
    if Process.get(:abort_admission_after_read, false) and String.starts_with?(query, "SELECT") and
         (String.contains?(query, "callback_id") or String.contains?(query, "max_throughput")) do
      Process.delete(:abort_admission_after_read)
      # This is a real nested transaction failure. DBConnection marks the
      # outer transaction aborted and returns {:error, :rollback} at its end.
      {:error, :test_abort} = Repo.transaction(fn -> Repo.rollback(:test_abort) end)
    end
  end

  test "independent claimants cannot multiply a daily rate", %{portal: portal, attrs: attrs} do
    committed(fn ->
      for n <- 1..5, do: Admission.admit(%{attrs | callback_id: "#{attrs.callback_id}-#{n}"})
    end)

    results =
      1..10
      |> Task.async_stream(fn _ -> committed(fn -> DispatchStore.claim(portal) end) end,
        max_concurrency: 10,
        timeout: 15_000
      )
      |> Enum.to_list()

    batches = for {:ok, {:ok, batch}} <- results, batch != nil, do: batch
    assert length(batches) == 1
    assert length(hd(batches).actions) == 1

    committed(fn ->
      DispatchStore.finish(hd(batches), :ok)
      assert {:ok, nil} = DispatchStore.claim(portal)
    end)
  end

  test "killing the admitting process after success cannot lose the callback", %{attrs: attrs} do
    parent = self()

    pid =
      spawn(fn ->
        result = committed(fn -> Admission.admit(attrs) end)
        send(parent, {:admitted, result})

        receive do
          :never -> :ok
        end
      end)

    ref = Process.monitor(pid)
    assert_receive {:admitted, {:ok, action}}, 5_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    committed(fn ->
      assert Repo.get!(ActionExecution, action.id).callback_id == attrs.callback_id
    end)
  end
end
