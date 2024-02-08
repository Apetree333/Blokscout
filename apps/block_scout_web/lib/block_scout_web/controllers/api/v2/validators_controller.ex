defmodule BlockScoutWeb.API.V2.ValidatorController do
  use BlockScoutWeb, :controller

  alias Explorer.Chain.ValidatorStability

  def stability_validators_list(conn, _params) do
    validators =
      ValidatorStability.get_all_validators(
        necessity_by_association: %{
          :address => :optional
        },
        api?: true
      )

    conn
    |> render(:stability_validators, %{validators: validators})
  end
end
