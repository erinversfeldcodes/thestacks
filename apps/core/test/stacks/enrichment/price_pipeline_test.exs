defmodule Stacks.Enrichment.PricePipelineTest do
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.Enrichment.{PricePipeline, Prices}

  @pipeline_name :test_price_pipeline

  setup do
    {:ok, pid} = PricePipeline.start_link(name: @pipeline_name)

    on_exit(fn ->
      ref = Process.monitor(pid)
      Process.exit(pid, :shutdown)
      receive do: ({:DOWN, ^ref, _, _, _} -> :ok)
    end)

    :ok
  end

  describe "handle_message/3 and handle_batch/4" do
    test "processes valid price data and inserts snapshot" do
      edition = insert(:book_edition)
      book = edition.book
      store = insert(:bookstore)

      data = %{
        "book_edition_id" => edition.id,
        "store_id" => store.id,
        "price_cents" => 29_900,
        "currency" => "ZAR",
        "in_stock" => true,
        "url" => "https://example.com/book"
      }

      ref = Broadway.test_message(@pipeline_name, data)
      assert_receive {:ack, ^ref, [_successful], []}, 5_000

      prices = Prices.latest_prices(book.id)
      assert length(prices) == 1
      assert hd(prices).price_cents == 29_900
    end

    test "rejects messages with missing required fields" do
      data = %{"currency" => "ZAR"}

      ref = Broadway.test_message(@pipeline_name, data)
      assert_receive {:ack, ^ref, [], [_failed]}, 5_000
    end

    test "handles batch of multiple messages" do
      edition = insert(:book_edition)
      book = edition.book
      store1 = insert(:bookstore)
      store2 = insert(:bookstore)

      data1 = %{
        "book_edition_id" => edition.id,
        "store_id" => store1.id,
        "price_cents" => 10_000,
        "currency" => "ZAR",
        "in_stock" => true,
        "url" => "https://store1.com/book"
      }

      data2 = %{
        "book_edition_id" => edition.id,
        "store_id" => store2.id,
        "price_cents" => 20_000,
        "currency" => "ZAR",
        "in_stock" => false,
        "url" => "https://store2.com/book"
      }

      ref1 = Broadway.test_message(@pipeline_name, data1)
      ref2 = Broadway.test_message(@pipeline_name, data2)

      assert_receive {:ack, ^ref1, [_], []}, 5_000
      assert_receive {:ack, ^ref2, [_], []}, 5_000

      prices = Prices.latest_prices(book.id)
      assert length(prices) == 2
    end
  end
end
