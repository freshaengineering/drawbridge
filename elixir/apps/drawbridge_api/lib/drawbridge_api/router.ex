defmodule DrawbridgeApi.Router do
  use Plug.Router

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json, Absinthe.Plug.Parser],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  # Order matters: /graphql must be matched before the catch-all / route,
  # otherwise GraphiQL would intercept GraphQL requests.
  forward("/graphql", to: Absinthe.Plug, init_opts: [schema: DrawbridgeApi.Schema])

  forward("/",
    to: Absinthe.Plug.GraphiQL,
    init_opts: [
      schema: DrawbridgeApi.Schema,
      interface: :playground
    ]
  )
end
