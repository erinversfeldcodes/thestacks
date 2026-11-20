defmodule Stacks.ModerationCpuFirstTest do
  @moduledoc """
      The CPU-first cascade order (`:cpu_first_identification`): one cpu_only
      vision call, catalogue resolution in core, and the GPU wakes ONLY for
      images the CPU tiers could not resolve.

      Each test steers the vision mock per payload shape — the `cpu_only` key
      is the discriminator — and in the tests that assert the GPU slept, the
      non-cpu branch RAISES, so a dispatch that should not happen cannot pass
      silently.
  """

  use Core.DataCase, async: false

  alias Stacks.AI.MockClient
  alias Stacks.Books.MockHttpClient
  alias Stacks.Moderation

  @test_image_b64 Base.encode64("fake image bytes")
  @isbn "9780743273565"
  @other_isbn "9780156001311"

  setup do
    :fuse.reset(:open_library_fuse)
    :fuse.reset(:google_books_fuse)

    previous = Application.get_env(:core, :cpu_first_identification)
    Application.put_env(:core, :cpu_first_identification, true)
    on_exit(fn -> Application.put_env(:core, :cpu_first_identification, previous) end)
    :ok
  end

  # The cpu-TITLE tier is off by default (measured net-negative on the first
  # full cascade eval); the tests that exercise it opt in explicitly.
  defp enable_cpu_title_resolution do
    previous = Application.get_env(:core, :cpu_title_resolution)
    Application.put_env(:core, :cpu_title_resolution, true)
    on_exit(fn -> Application.put_env(:core, :cpu_title_resolution, previous) end)
  end

  defp cpu_only?(payload), do: Map.get(payload, :cpu_only) == true

  defp barcode_response(isbn) do
    {:ok,
     %{
       "classification" => "CLASSIFICATION_RESULT_BOOK",
       "confidence" => 1.0,
       "books" => [
         %{
           "title" => nil,
           "author" => nil,
           "potential_isbns" => [isbn],
           "raw_text" => nil,
           "confidence" => 1.0
         }
       ],
       "model_used" => "local_ocr",
       "tier" => "ANALYSIS_TIER_BARCODE"
     }}
  end

  defp cpu_read_response(attempt) do
    {:ok,
     %{
       "classification" => "CLASSIFICATION_RESULT_UNSPECIFIED",
       "confidence" => 0.0,
       "books" => [],
       "model_used" => "tesseract",
       "tier" => "ANALYSIS_TIER_UNSPECIFIED",
       "ocr_attempt" => attempt
     }}
  end

  defp full_gpu_response(isbn) do
    {:ok,
     %{
       "classification" => "CLASSIFICATION_RESULT_BOOK",
       "confidence" => 0.9,
       "books" => [
         %{
           "title" => nil,
           "author" => nil,
           "potential_isbns" => [isbn],
           "raw_text" => nil,
           "confidence" => 0.9
         }
       ],
       "model_used" => "mock"
     }}
  end

  test "a cpu barcode answer resolves without waking the GPU" do
    MockClient.put_response("analyze", fn payload ->
      if cpu_only?(payload) do
        barcode_response(@isbn)
      else
        raise "the GPU path was dispatched for a barcode-answered image"
      end
    end)

    assert {:ok, %{resolved: [book]}} =
             Moderation.run_pipeline(%{
               image_b64: @test_image_b64,
               book_attrs: %{"title" => "Stored"}
             })

    assert [edition | _] = book.editions
    assert edition.isbn == @isbn
  end

  test "a cover-text read resolves bag-of-words without waking the GPU (tier opted in)" do
    enable_cpu_title_resolution()

    MockHttpClient.put_response(
      "openlibrary.org/search.json",
      {:ok,
       %{
         "docs" => [
           %{
             "isbn" => [@isbn],
             "title" => "The Great Gatsby",
             "author_name" => ["F. Scott Fitzgerald"],
             "first_publish_year" => 1925
           }
         ]
       }}
    )

    MockClient.put_response("analyze", fn payload ->
      if cpu_only?(payload) do
        # No title line was picked out — the raw words are the whole signal.
        cpu_read_response(%{
          "title" => nil,
          "author" => nil,
          "raw_text" => "THE GREAT GATSBY F SCOTT FITZGERALD",
          "confidence" => 0.42,
          "answered" => false,
          "engine" => "tesseract"
        })
      else
        raise "the GPU path was dispatched for a cpu-resolvable read"
      end
    end)

    assert {:ok, %{resolved: [book]}} =
             Moderation.run_pipeline(%{
               image_b64: @test_image_b64,
               book_attrs: %{"title" => "Stored"}
             })

    assert [edition | _] = book.editions
    assert edition.isbn == @isbn
  end

  test "by DEFAULT a cover-text read never answers — the GPU does" do
    # ⛔ The first full cascade eval measured cpu-title-as-FINAL net-negative
    # (clear_cover 22/22 → 6/22; three negatives identified as books, past a
    # classify guard that never ran). Until the acceptance design can tell a
    # partial title from an identification, a read is evidence for the
    # SHADOW measurement, not an answer.
    #
    # ⬛ ANTI-VACUITY: the catalogue IS stubbed to resolve this read — without
    # this stub the CPU resolution would miss and fall through regardless,
    # and forcing the tier on left this test green (measured, probe S, first
    # attempt). The flag must be the ONLY thing standing between the read
    # and a CPU-final answer, or the assertions below assert nothing.
    MockHttpClient.put_response(
      "openlibrary.org/search.json",
      {:ok,
       %{
         "docs" => [
           %{
             "isbn" => [@isbn],
             "title" => "The Great Gatsby",
             "author_name" => ["F. Scott Fitzgerald"],
             "first_publish_year" => 1925
           }
         ]
       }}
    )

    parent = self()

    MockClient.put_response("analyze", fn payload ->
      send(parent, {:vision_call, cpu_only?(payload)})

      if cpu_only?(payload) do
        cpu_read_response(%{
          "title" => "The Great Gatsby",
          "author" => "F. Scott Fitzgerald",
          "raw_text" => "THE GREAT GATSBY F SCOTT FITZGERALD",
          "confidence" => 0.99,
          "answered" => false,
          "engine" => "tesseract"
        })
      else
        full_gpu_response(@isbn)
      end
    end)

    assert {:ok, %{resolved: [_book]}} =
             Moderation.run_pipeline(%{
               image_b64: @test_image_b64,
               book_attrs: %{"title" => "Stored"}
             })

    # Both calls happened: the read was collected, and the ANSWER came from
    # the full path — even for a perfect-looking read.
    assert_received {:vision_call, true}
    assert_received {:vision_call, false}
  end

  test "a cpu pass that read nothing falls through to the full analyze" do
    parent = self()

    MockClient.put_response("analyze", fn payload ->
      send(parent, {:vision_call, cpu_only?(payload)})

      if cpu_only?(payload) do
        cpu_read_response(nil)
      else
        full_gpu_response(@isbn)
      end
    end)

    assert {:ok, %{resolved: [_book]}} =
             Moderation.run_pipeline(%{
               image_b64: @test_image_b64,
               book_attrs: %{"title" => "Stored"}
             })

    # ⬛ Order matters: the cpu pass ran first, the GPU second.
    assert_received {:vision_call, true}
    assert_received {:vision_call, false}
  end

  test "a read the catalogue cannot resolve falls through rather than rejecting" do
    enable_cpu_title_resolution()
    MockHttpClient.put_response("openlibrary.org/search.json", {:ok, %{"docs" => []}})
    MockHttpClient.put_response("googleapis.com", {:ok, %{"items" => []}})
    parent = self()

    MockClient.put_response("analyze", fn payload ->
      send(parent, {:vision_call, cpu_only?(payload)})

      if cpu_only?(payload) do
        cpu_read_response(%{
          "title" => nil,
          "author" => nil,
          "raw_text" => "WORDS THE CATALOGUE HAS NEVER SEEN",
          "confidence" => 0.3,
          "answered" => false,
          "engine" => "tesseract"
        })
      else
        full_gpu_response(@isbn)
      end
    end)

    assert {:ok, %{resolved: [_book]}} =
             Moderation.run_pipeline(%{
               image_b64: @test_image_b64,
               book_attrs: %{"title" => "Stored"}
             })

    assert_received {:vision_call, true}
    assert_received {:vision_call, false}
  end

  test "a retry carrying excluded ISBNs never offers the cpu tier again" do
    # ⬛ A REJECTION IS A MISS: the first live drive watched the cpu tier
    # resolve three different wrong-but-real books for one partial title read
    # while the GPU never woke. The non-cpu branch is the ONLY branch a retry
    # may take — the cpu branch raising is what makes this test able to fail.
    MockClient.put_response("analyze", fn payload ->
      if cpu_only?(payload) do
        raise "the cpu tier ran on a retry that carries exclusions"
      else
        full_gpu_response(@other_isbn)
      end
    end)

    context = %{
      image_b64: @test_image_b64,
      excluded_isbns: [@isbn],
      book_attrs: %{"title" => "Stored"}
    }

    assert {:ok, %{resolved: [book]}} = Moderation.run_pipeline(context)
    assert [edition | _] = book.editions
    assert edition.isbn == @other_isbn
  end

  test "a retry carrying excluded books (title rejections) escalates the same way" do
    MockClient.put_response("analyze", fn payload ->
      if cpu_only?(payload) do
        raise "the cpu tier ran on a retry that carries exclusions"
      else
        full_gpu_response(@isbn)
      end
    end)

    context = %{
      image_b64: @test_image_b64,
      excluded_books: ["The Book of the Dead by E. A. Wallis Budge"],
      book_attrs: %{"title" => "Stored"}
    }

    assert {:ok, %{resolved: [_book]}} = Moderation.run_pipeline(context)
  end

  test "a cpu pass transport failure costs nothing but the fallthrough" do
    parent = self()

    MockClient.put_response("analyze", fn payload ->
      send(parent, {:vision_call, cpu_only?(payload)})

      if cpu_only?(payload) do
        {:error, :service_unavailable}
      else
        full_gpu_response(@isbn)
      end
    end)

    assert {:ok, %{resolved: [_book]}} =
             Moderation.run_pipeline(%{
               image_b64: @test_image_b64,
               book_attrs: %{"title" => "Stored"}
             })

    assert_received {:vision_call, true}
    assert_received {:vision_call, false}
  end

  test "the flag off restores the single-call order — the planted switch proof" do
    Application.put_env(:core, :cpu_first_identification, false)
    parent = self()

    MockClient.put_response("analyze", fn payload ->
      send(parent, {:vision_call, Map.get(payload, :cpu_only)})
      full_gpu_response(@isbn)
    end)

    assert {:ok, %{resolved: [_book]}} =
             Moderation.run_pipeline(%{
               image_b64: @test_image_b64,
               book_attrs: %{"title" => "Stored"}
             })

    # Exactly one call, and it never carried the cpu_only key.
    assert_received {:vision_call, nil}
    refute_received {:vision_call, _}
  end
end
