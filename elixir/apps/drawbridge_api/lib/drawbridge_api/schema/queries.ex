defmodule DrawbridgeApi.Schema.Queries do
  use Absinthe.Schema.Notation

  alias DrawbridgeApi.Schema.Resolvers

  object :service_queries do
    field :services, non_null(list_of(non_null(:service))) do
      resolve(&Resolvers.list_services/3)
    end

    field :service, :service do
      arg(:name, non_null(:string))
      resolve(&Resolvers.get_service/3)
    end

    field :setup_prompt, non_null(:string) do
      resolve(&Resolvers.setup_prompt/3)
    end

    field :schema_sdl, non_null(:string) do
      resolve(&Resolvers.schema_sdl/3)
    end
  end
end
