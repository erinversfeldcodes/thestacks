defmodule Mix.Tasks.ProtoSync.Descriptor do
  @moduledoc false

  @doc """
  Parses a JSON FileDescriptorSet produced by `buf build`.

  Shells out to `buf build proto/ --output /dev/stdout --as-file-descriptor-set`
  and decodes the JSON output.
  """
  def parse!(repo_root) do
    proto_dir = Path.join(repo_root, "proto")
    tmp_path = Path.join(System.tmp_dir!(), "stacks_descriptor.json")

    {_output, exit_code} =
      System.cmd(
        "buf",
        ["build", "--as-file-descriptor-set", "-o", "#{tmp_path}#format=json"],
        cd: proto_dir,
        stderr_to_stdout: true
      )

    unless exit_code == 0 do
      Mix.raise("buf build failed (exit #{exit_code}). Is buf installed and proto/ valid?")
    end

    json = File.read!(tmp_path)
    File.rm(tmp_path)
    Jason.decode!(json)
  end

  @doc """
  Extracts fields for a specific message from the parsed descriptor.

  Matches `proto_file` against `file[n].name` and `proto_message` against
  `file[n].messageType[m].name` in the FileDescriptorSet.

  Returns a list of field maps: `%{name, number, type, type_name, label}`.
  """
  def extract_fields(descriptor, proto_file, proto_message) do
    file_entry =
      Enum.find(descriptor["file"], fn f -> f["name"] == proto_file end) ||
        Mix.raise("Proto file #{proto_file} not found in descriptor.")

    message =
      Enum.find(file_entry["messageType"] || [], fn m -> m["name"] == proto_message end) ||
        Mix.raise("Message #{proto_message} not found in #{proto_file}.")

    (message["field"] || [])
    |> Enum.sort_by(& &1["number"])
    |> Enum.map(fn field ->
      %{
        name: field["name"],
        number: field["number"],
        type: field["type"],
        type_name: field["typeName"],
        label: field["label"]
      }
    end)
  end
end
