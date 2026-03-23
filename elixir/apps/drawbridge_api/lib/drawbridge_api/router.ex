defmodule DrawbridgeApi.Router do
  use Plug.Router

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json, Absinthe.Plug.Parser],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  forward("/graphql", to: Absinthe.Plug, init_opts: [schema: DrawbridgeApi.Schema])

  forward("/",
    to: Absinthe.Plug.GraphiQL,
    init_opts: [
      schema: DrawbridgeApi.Schema,
      interface: :playground
    ]
  )
end
