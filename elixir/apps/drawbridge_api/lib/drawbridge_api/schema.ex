defmodule DrawbridgeApi.Schema do
  use Absinthe.Schema

  import_types(DrawbridgeApi.Schema.ServiceTypes)
  import_types(DrawbridgeApi.Schema.Queries)
  import_types(DrawbridgeApi.Schema.Mutations)

  query do
    import_fields(:service_queries)
  end

  mutation do
    import_fields(:service_mutations)
  end
end
