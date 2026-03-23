defmodule DrawbridgeApi.Schema.Mutations do
  use Absinthe.Schema.Notation

  alias DrawbridgeApi.Schema.Resolvers

  object :service_mutations do
    field :boot_service, :service do
      arg(:name, non_null(:string))
      resolve(&Resolvers.boot_service/3)
    end

    field :stop_service, :service do
      arg(:name, non_null(:string))
      resolve(&Resolvers.stop_service/3)
    end
  end
end
