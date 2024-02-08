defmodule BlockScoutWeb.API.V2.ValidatorView do
  use BlockScoutWeb, :view

  alias BlockScoutWeb.API.V2.{ApiView, Helper, TokenView}

  def render("stability_validators.json", %{validators: validators}) do
    %{"items" => Enum.map(validators, &prepare_validator(&1)), "next_page_params" => nil}
  end

  defp prepare_validator(validator) do
    %{
      "address" => Helper.address_with_info(nil, validator.address, validator.address_hash, true),
      "state" => validator.state
    }
  end
end
