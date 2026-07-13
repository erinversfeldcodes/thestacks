Postgrex.Types.define(
  Core.PostgrexTypes,
  [Core.Extensions.UUIDString] ++ Pgvector.extensions()
)
