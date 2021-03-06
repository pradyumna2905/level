defmodule Level.Users do
  @moduledoc """
  The Users context.
  """

  import Ecto.Query
  import Level.Gettext

  alias Ecto.Multi
  alias Level.AssetStore
  alias Level.Repo
  alias Level.Spaces
  alias Level.Users.PushSubscription
  alias Level.Users.Reservation
  alias Level.Users.User
  alias Level.WebPush

  @doc """
  Regex for validating handle format.
  """
  def handle_format do
    ~r/^(?>[A-Za-z][A-Za-z0-9-\.]*[A-Za-z0-9])$/
  end

  @doc """
  Fetches a user by id.
  """
  @spec get_user_by_id(String.t()) :: {:ok, User.t()} | {:error, String.t()}
  def get_user_by_id(id) do
    case Repo.get(User, id) do
      %User{} = user ->
        {:ok, user}

      _ ->
        {:error, dgettext("errors", "User not found")}
    end
  end

  @doc """
  Generates a changeset for creating a user.
  """
  @spec create_user_changeset(User.t(), map()) :: Ecto.Changeset.t()
  def create_user_changeset(user, params \\ %{}) do
    User.create_changeset(user, params)
  end

  @doc """
  Creates a new user.
  """
  @spec create_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_user(params) do
    %User{}
    |> create_user_changeset(params)
    |> Repo.insert()
  end

  @doc """
  Creates a reservation.
  """
  @spec create_reservation(map()) :: {:ok, Reservation.t()} | {:error, Ecto.Changeset.t()}
  def create_reservation(params) do
    %Reservation{}
    |> Reservation.create_changeset(params)
    |> Repo.insert()
  end

  @doc """
  Updates a user.
  """
  @spec update_user(User.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | String.t()}
  def update_user(user, params) do
    Multi.new()
    |> Multi.update(:user, User.update_changeset(user, params))
    |> Multi.run(:update_space_users, &update_space_users/1)
    |> Repo.transaction()
    |> handle_user_update()
  end

  defp update_space_users(%{user: user}) do
    user
    |> Ecto.assoc(:space_users)
    |> Repo.all()
    |> Enum.each(copy_user_params(user))

    {:ok, true}
  end

  defp copy_user_params(user) do
    fn space_user ->
      Spaces.update_space_user(space_user, %{
        first_name: user.first_name,
        last_name: user.last_name,
        handle: user.handle,
        avatar: user.avatar
      })
    end
  end

  defp handle_user_update({:ok, %{user: user}}) do
    {:ok, user}
  end

  defp handle_user_update({:error, :user, %Ecto.Changeset{} = changeset, _}) do
    {:error, changeset}
  end

  defp handle_user_update(_) do
    {:error, dgettext("errors", "An unexpected error occurred")}
  end

  @doc """
  Updates the user's avatar.
  """
  @spec update_avatar(User.t(), String.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | String.t()}
  def update_avatar(user, raw_data) do
    raw_data
    |> AssetStore.upload_avatar()
    |> set_user_avatar(user)
  end

  defp set_user_avatar({:ok, filename}, user) do
    update_user(user, %{avatar: filename})
  end

  defp set_user_avatar(:error, _user) do
    {:error, dgettext("errors", "An error occurred updating your avatar")}
  end

  @doc """
  Generates the avatar URL for a given filename.
  """
  @spec avatar_url(String.t() | nil) :: String.t() | nil
  def avatar_url(nil), do: nil
  def avatar_url(filename), do: AssetStore.avatar_url(filename)

  @doc """
  Count the number of reservations.
  """
  @spec reservation_count() :: integer()
  def reservation_count do
    Repo.one(from(r in Reservation, select: count(r.id)))
  end

  @doc """
  Inserts a push subscription (gracefully de-duplicated).
  """
  @spec create_push_subscription(User.t(), String.t()) ::
          {:ok, String.t()} | {:error, atom()} | {:error, Ecto.Changeset.t()}
  def create_push_subscription(%User{id: user_id}, data) do
    with {:ok, subscription} <- WebPush.parse_subscription(data),
         {:ok, _} <- persist_push_subscription(user_id, data) do
      {:ok, subscription}
    else
      err ->
        err
    end
  end

  defp persist_push_subscription(user_id, data) do
    %PushSubscription{}
    |> PushSubscription.create_changeset(%{user_id: user_id, data: data})
    |> Repo.insert(on_conflict: :nothing)
    |> handle_create_push_subscription()
  end

  defp handle_create_push_subscription({:ok, %PushSubscription{data: data}}) do
    {:ok, data}
  end

  defp handle_create_push_subscription(err), do: err

  @doc """
  Fetches all push subscriptions for the given user.
  """
  @spec get_push_subscriptions(String.t()) :: [WebPush.Subscription.t()]
  def get_push_subscriptions(user_id) do
    query = from ps in PushSubscription, where: ps.user_id == ^user_id

    query
    |> Repo.all()
    |> parse_push_subscription_records()
  end

  defp parse_push_subscription_records(records) do
    records
    |> Enum.map(fn record ->
      case WebPush.parse_subscription(record.data) do
        {:ok, subscription} -> subscription
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
