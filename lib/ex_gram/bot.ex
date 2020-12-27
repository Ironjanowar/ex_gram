defmodule ExGram.Bot do
  defmacro __using__(ops) do
    name =
      case Keyword.fetch(ops, :name) do
        {:ok, n} -> n
        _ -> raise "name parameter is mandatory"
      end

    username = Keyword.fetch(ops, :username)
    setup_commands = Keyword.get(ops, :setup_commands, false)

    commands = quote do: commands()

    regexes = quote do: regexes()

    middlewares = quote do: middlewares()

    # quote location: :keep do
    quote do
      use Supervisor
      use ExGram.Middleware.Builder

      import ExGram.Dsl

      @behaviour ExGram.Handler

      def name(), do: unquote(name)

      def start_link(opts) when is_list(opts) do
        name = opts[:name] || name()
        supervisor_name = String.to_atom(Atom.to_string(name) <> "_supervisor")
        params = {:ok, opts[:method], opts[:token], name}
        Supervisor.start_link(__MODULE__, params, name: supervisor_name)
      end

      def start_link(m, token \\ nil) do
        start_link(method: m, token: token, name: unquote(name))
      end

      defp start_link(m, token, name) do
        start_link(method: m, token: token, name: name)
      end

      def init({:ok, updates_method, token, name}) do
        {:ok, _} = Registry.register(Registry.ExGram, name, token)

        updates_worker =
          case updates_method do
            :webhook ->
              raise "Not implemented yet"

            :noup ->
              ExGram.Updates.Noup

            :polling ->
              ExGram.Updates.Polling

            :test ->
              ExGram.Updates.Test

            nil ->
              raise "No updates method received, try with :polling or your custom module"

            other ->
              other
          end

        maybe_setup_commands(unquote(setup_commands), unquote(commands), token)

        bot_info = maybe_fetch_bot(unquote(username), token)

        dispatcher_opts = %ExGram.Dispatcher{
          name: name,
          bot_info: bot_info,
          dispatcher_name: name,
          commands: unquote(commands),
          regex: unquote(regexes),
          middlewares: unquote(middlewares),
          handler: handle_mf(),
          error_handler: handle_error_mf()
        }

        children = [
          {ExGram.Dispatcher, dispatcher_opts},
          {updates_worker, {:bot, name, :token, token}}
        ]

        Supervisor.init(children, strategy: :one_for_one)
      end

      def message(from, message) do
        GenServer.call(name(), {:message, from, message})
      end

      # Default implementations
      def handle(msg, _cnt) do
        error = %ExGram.Error{code: :not_handled, message: "Message not handled: #{inspect(msg)}"}
        handle_error(error)
      end

      def handle_error(error) do
        error
        # IO.inspect("Error received: #{inspect(error)}")
      end

      defoverridable ExGram.Handler

      defp handle_mf(), do: {__MODULE__, :handle}
      defp handle_error_mf(), do: {__MODULE__, :handle_error}

      # defp do_handle(msg, cnt), do: __MODULE__.handle(msg, cnt)
      # defp do_handle_error(error), do: __MODULE__.handle_error(error)

      defp maybe_fetch_bot(username, _token) when is_binary(username),
        do: %ExGram.Model.User{username: username, is_bot: true}

      defp maybe_fetch_bot(_username, token) do
        with {:ok, bot} <- ExGram.get_me(token: token) do
          bot
        else
          _ -> nil
        end
      end

      defp maybe_setup_commands(true, commands, token) do
        send_commands =
          commands
          |> Stream.filter(fn command ->
            not is_nil(command[:description])
          end)
          |> Enum.map(fn command ->
            %ExGram.Model.BotCommand{
              command: command[:command],
              description: command[:description]
            }
          end)

        ExGram.set_my_commands(send_commands, token: token)
      end

      defp maybe_setup_commands(_, _commands, _token), do: :nop
    end
  end
end
