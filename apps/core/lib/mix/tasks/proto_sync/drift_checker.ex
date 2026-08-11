defmodule Mix.Tasks.ProtoSync.DriftChecker do
  @moduledoc """
  Compares generated content against disk. Drift means two different
  things (354): a TRACKED file diverging from its `.proto` source is a real
  defect and fails the build; a GITIGNORED file can only be locally stale
  (CI regenerates from scratch), so given `repo_root` it is regenerated and
  reported `{:regenerated, path}`. Without `repo_root`, every drift fails —
  the safe direction.
  """

  @doc """
  Compares generated content against an existing file on disk.

  Returns:

    * `:ok` — the files match (after whitespace normalization)
    * `{:regenerated, path}` — they differed but the file is gitignored, so it
      was rewritten from the generated content (only when `repo_root` is given)
    * `{:drift, path, diff}` — they differ and the file is not provably
      disposable, or the file does not exist

  `repo_root` is optional so the pure comparison stays available to tests and to
  callers that have no working tree to classify against.
  """
  def check(expected_content, file_path, repo_root \\ nil) do
    if File.exists?(file_path) do
      actual = File.read!(file_path)

      if normalize(actual) == normalize(expected_content) do
        :ok
      else
        resolve(expected_content, file_path, repo_root, generate_diff(actual, expected_content))
      end
    else
      resolve(
        expected_content,
        file_path,
        repo_root,
        "file not found — expected generated file at #{file_path}"
      )
    end
  end

  defp resolve(expected_content, file_path, repo_root, diff) do
    if classify(file_path, repo_root) == "ignored" do
      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, expected_content)
      {:regenerated, file_path}
    else
      {:drift, file_path, diff}
    end
  end

  defp classify(_file_path, nil), do: "untracked"

  defp classify(file_path, repo_root) do
    script = Path.join(repo_root, "scripts/generated-file-class.sh")

    if File.exists?(script) do
      case System.cmd("bash", [script, file_path], stderr_to_stdout: true) do
        {output, 0} -> String.trim(output)
        _ -> "untracked"
      end
    else
      "untracked"
    end
  end

  defp normalize(content) do
    content
    |> String.trim()
    |> String.replace(~r/\s+$\n/m, "\n")
  end

  defp generate_diff(actual, expected) do
    actual_lines = String.split(normalize(actual), "\n")
    expected_lines = String.split(normalize(expected), "\n")

    List.myers_difference(actual_lines, expected_lines)
    |> Enum.flat_map(fn
      {:eq, _} -> []
      {:del, lines} -> Enum.map(lines, &"- #{&1}")
      {:ins, lines} -> Enum.map(lines, &"+ #{&1}")
    end)
    |> Enum.join("\n")
    |> case do
      "" -> "(whitespace-only differences)"
      diff -> diff
    end
  end
end
