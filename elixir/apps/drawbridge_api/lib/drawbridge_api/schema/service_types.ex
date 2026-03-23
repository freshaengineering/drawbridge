defmodule DrawbridgeApi.Schema.ServiceTypes do
  use Absinthe.Schema.Notation

  enum :service_state do
    value(:not_pulled, as: :not_pulled)
    value(:stopped, as: :stopped)
    value(:booting, as: :booting)
    value(:running, as: :running)
  end

  object :port_mapping do
    field(:host, non_null(:integer))
    field(:container, non_null(:integer))
  end

  object :service do
    field(:name, non_null(:string))
    field(:state, non_null(:service_state))
    field(:hostname, :string)
    field(:image, non_null(:string))
    field(:ports, non_null(list_of(non_null(:port_mapping))))
    field(:connections, non_null(:integer))
    field(:uptime, :integer)
    field(:ip, :string)
    field(:depends_on, non_null(list_of(non_null(:string))))
  end
end
