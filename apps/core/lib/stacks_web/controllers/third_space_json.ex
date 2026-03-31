defmodule StacksWeb.ThirdSpaceJSON do
  def index(%{third_spaces: spaces}) do
    %{third_spaces: Enum.map(spaces, &render_space/1)}
  end

  defp render_space(space) do
    %{
      id: space.id,
      name: space.name,
      type: space.type,
      city: space.city,
      country_code: space.country_code,
      website_url: space.website_url,
      verified: space.verified,
      upcoming_events: Enum.map(space.upcoming_events, &render_event/1)
    }
  end

  defp render_event(event) do
    %{
      id: event.id,
      title: event.title,
      event_date: event.event_date,
      ends_at: event.ends_at
    }
  end
end
