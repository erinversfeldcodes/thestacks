# Dialyzer false positives
#
# call_without_opaque: Ecto.Multi uses an opaque MapSet internally.
# Dialyzer cannot resolve the opaque subterms after Multi.new(), producing
# spurious warnings on every chained Multi call. This is a known limitation;
# see https://github.com/elixir-ecto/ecto/issues/3932
[
  {"lib/stacks/accounts.ex", :call_without_opaque},
  {"lib/stacks/books.ex", :call_without_opaque},
  {"lib/stacks/gdpr/deletion.ex", :call_without_opaque},
  {"lib/stacks/shelving.ex", :call_without_opaque}
]
