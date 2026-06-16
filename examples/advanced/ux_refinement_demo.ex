defmodule Raxol.Examples.UXRefinementDemo do
  use Raxol.Core.Runtime.Application
  # Remove use Component
  # use Raxol.UI.Components.Base.Component
  # Removed conflicting behaviour
  # @behaviour Raxol.UI.Components.Base.Component

  @moduledoc """
  Demo example showcasing the User Experience Refinement components.

  This example demonstrates:
  1. Focus management with keyboard navigation
  2. Contextual hints for different components
  3. Visual focus indication
  4. Accessibility support

  Run this example with:
  ```
  $ mix run -e "Raxol.Examples.UXRefinementDemo.run()"
  ```
  """

  alias Raxol.Core.UXRefinement
  alias Raxol.Core.FocusManager
  alias Raxol.UI.Components.FocusRing
  alias Raxol.View.Elements, as: UI
  alias Raxol.Core.Runtime.ProcessStore
  require Raxol.Core.Runtime.Log

  require UI

  defstruct [
    # Focus state
    # Keep track of current UI view if needed
    current_view: :main,
    # Store form input values
    form_data: %{username: "", password: ""},
    # ID of the currently focused component
    focused_component: "username_input",
    # Flag to control help dialog visibility
    show_help: false,
    # State for the focus ring component (handled by component itself)
    focus_ring_model: nil
    # Potentially add other UI state here
  ]

  @doc """
  Run the UX Refinement demo application.
  """
  def run do
    Raxol.Core.Runtime.Log.info("Starting UX Refinement Demo Application...")

    # Start Raxol with this module as the Application
    # Pass an empty map as initial opts for init/1
    Raxol.Core.Runtime.Lifecycle.start_application(__MODULE__, %{})
  end

  @doc """
  Initialize the application state and perform setup.
  """
  @impl Raxol.Core.Runtime.Application
  def init(_opts) do
    # Add logging
    Raxol.Core.Runtime.Log.info("Initializing UX Refinement Demo...")

    # --- Setup moved from run/0 ---
    # Enable UX refinement features
    UXRefinement.enable_feature(:keyboard_nav)
    UXRefinement.enable_feature(:focus_management)
    UXRefinement.enable_feature(:hints)
    UXRefinement.enable_feature(:response_optimization)
    # Note: FocusRing feature enabled by default or via theme integration

    # Register hints for components
    UXRefinement.register_hint(
      "username_input",
      "Enter your username (letters and numbers only)"
    )

    UXRefinement.register_hint(
      "password_input",
      "Enter a secure password (minimum 8 characters)"
    )

    UXRefinement.register_hint("login_button", "Press Enter to log in")

    UXRefinement.register_hint(
      "reset_button",
      "Press Enter to reset the form"
    )

    UXRefinement.register_hint(
      "help_button",
      "Press Enter to open the help dialog"
    )

    # Register focusable components
    FocusManager.register_focusable("username_input", 1,
      announce: "Username input field. Enter your username."
    )

    FocusManager.register_focusable("password_input", 2,
      announce: "Password input field. Enter your password."
    )

    FocusManager.register_focusable("login_button", 3,
      group: :buttons,
      announce: "Login button"
    )

    FocusManager.register_focusable("reset_button", 4,
      group: :buttons,
      announce: "Reset button"
    )

    FocusManager.register_focusable("help_button", 5,
      group: :buttons,
      announce: "Help button"
    )

    # Set initial focus
    # Initial focus is username_input
    FocusManager.set_initial_focus("username_input")

    # Mock element positions for the focus ring
    element_registry = %{
      "username_input" => {10, 5, 30, 3},
      "password_input" => {10, 9, 30, 3},
      "login_button" => {10, 13, 10, 3},
      "reset_button" => {22, 13, 10, 3},
      "help_button" => {34, 13, 10, 3}
    }

    ProcessStore.put(:element_position_registry, element_registry)
    # --- End of setup from run/0 ---

    # Return initial state
    # Return the struct
    {:ok,
     %__MODULE__{
       form_data: %{username: "", password: ""},
       # Updated initial focus ID
       focused_component: "username_input",
       show_help: false,
       # FocusRing manages its own state
       focus_ring_model: nil
     }}
  end

  @doc """
  Render the UX refinement demo UI.
  """
  @impl Raxol.Core.Runtime.Application
  @dialyzer {:nowarn_function, view: 1}
  def view(state) do
    focused_id = state.focused_component

    # all_hints = get_hints_for(focused_id) # Assuming get_hints_for exists and is used elsewhere

    # --- Calculate focus position BEFORE the main component list ---
    element_registry = ProcessStore.get(:element_position_registry, %{})
    focused_position = Map.get(element_registry, focused_id)

    # --- Conditionally create the focus ring component ---
    focus_ring_component =
      case focused_position do
        # Explicitly return nil if no position
        nil ->
          nil

        _ ->
          # Raxol.View.Elements.component(
          #   Raxol.UI.Components.FocusRing,
          #   id: :focus_ring,
          #   model: state.focus_ring_model,
          #   focused_element_id: focused_id,
          #   focused_element_position: focused_position
          # )
          # Construct component map directly
          %{
            type: Raxol.UI.Components.FocusRing,
            id: :focus_ring,
            # Pass props directly, assuming component handles its own model state
            # model: state.focus_ring_model,
            focused_element_id: focused_id,
            focused_element_position: focused_position
          }
      end

    # Raxol.View.Elements.component Raxol.UI.Components.AppContainer, id: :app_container do
    # Use AppContainer map directly as the root element
    %{
      type: Raxol.UI.Components.AppContainer,
      id: :app_container,
      children: [
        # START OF LIST
        UI.panel title: "Login Form" do
          UI.box do
            [
              # Main content area (takes up most space)
              UI.box style: %{height: "fill-1"} do
                # Layout the three main sections
                UI.row height: "100%" do
                  UI.column padding: 1 do
                    # Wrap all children in an explicit list
                    [
                      case state.show_help do
                        true ->
                          render_help_dialog()

                        false ->
                          # Form elements need to be a list too for the outer list
                          [
                            UI.row padding_bottom: 1 do
                              label_element =
                                Raxol.View.Elements.label("Username:",
                                  style: %{width: 10}
                                )

                              input_element =
                                UI.text_input(
                                  id: "username_input",
                                  value: state.form_data.username,
                                  width: 30,
                                  focus: focused_id == "username_input"
                                )

                              [label_element, input_element]
                            end,
                            UI.row padding_bottom: 1 do
                              label_element =
                                Raxol.View.Elements.label("Password:",
                                  style: %{width: 10}
                                )

                              input_element =
                                UI.text_input(
                                  id: "password_input",
                                  value: state.form_data.password,
                                  width: 30,
                                  password: true,
                                  focus: focused_id == "password_input"
                                )

                              [label_element, input_element]
                            end,
                            UI.row padding_top: 1 do
                              login_button =
                                UI.button(
                                  id: "login_button",
                                  label: "Login",
                                  width: 10,
                                  focus: focused_id == "login_button"
                                )

                              space_element = Raxol.View.Elements.label(" ")

                              reset_button =
                                UI.button(
                                  id: "reset_button",
                                  label: "Reset",
                                  width: 10,
                                  focus: focused_id == "reset_button"
                                )

                              space_element2 = Raxol.View.Elements.label(" ")

                              help_button =
                                UI.button(
                                  id: "help_button",
                                  label: "Help",
                                  width: 10,
                                  focus: focused_id == "help_button"
                                )

                              [
                                login_button,
                                space_element,
                                reset_button,
                                space_element2,
                                help_button
                              ]
                            end
                          ]
                      end
                    ]
                  end
                end
              end,

              # Hint display at the bottom
              # Raxol.View.Elements.component(
              #   Raxol.UI.Components.HintDisplay,
              #   id: :hint_display,
              #   hints: all_hints,
              #   position: :bottom
              #   # Style can be added here if needed
              # )
              # Construct component map directly
              %{
                type: Raxol.UI.Components.HintDisplay,
                id: :hint_display,
                hints: get_hints_for(state.focused_component),
                position: :bottom
                # Style can be added here if needed
              },

              # Add the pre-calculated focus ring component (will be nil if not needed)
              focus_ring_component
            ]
          end
        end
      ]
    }
  end

  @doc """
  Update the application state based on events.
  """
  @impl Raxol.Core.Runtime.Application
  def update(model, msg) do
    new_model =
      case msg do
        # Text input updates
        {:input, "username_input", value} ->
          %{model | form_data: %{model.form_data | username: value}}

        {:input, "password_input", value} ->
          %{model | form_data: %{model.form_data | password: value}}

        # Button clicks
        {:click, "login_button"} ->
          # In a real app, this would handle authentication
          model

        {:click, "reset_button"} ->
          %{model | username: "", password: ""}

        {:click, "help_button"} ->
          %{model | show_help: true}

        # Focus change events
        {:focus_change, _old_focus, new_focus} ->
          # Update the focus ring position
          updated_focus_ring =
            FocusRing.update(
              model.focus_ring_model,
              {:focus_change, nil, new_focus}
            )

          %{
            model
            | focused_component: new_focus,
              focus_ring_model: updated_focus_ring
          }

        # Close help dialog
        {:close_help} ->
          %{model | show_help: false}

        # Default case
        _ ->
          model
      end

    # Return {new_state, commands}
    {new_model, []}
  end

  # Private functions

  @dialyzer {:nowarn_function, render_help_dialog: 0}
  defp render_help_dialog do
    # Use the panel macro directly
    rendered_dialog =
      UI.panel title: "Help",
               padding: 1,
               height: 12,
               width: 40,
               border: true,
               style: %{
                 position: :absolute,
                 top: "50%",
                 left: "50%",
                 transform: "translate(-50%, -50%)"
               } do
        UI.column do
          [
            Raxol.View.Elements.label(
              content: "This is a demo of the UX Refinement features in Raxol."
            ),
            Raxol.View.Elements.label(
              content: "Use Tab and Shift+Tab to navigate between form fields."
            ),
            Raxol.View.Elements.label(
              content: "The focus ring indicates which element is focused."
            ),
            Raxol.View.Elements.label(
              content: "Hints at the bottom provide context for each element."
            ),
            UI.row padding_top: 2 do
              [
                UI.button(
                  id: "close_help",
                  label: "Close",
                  width: 10,
                  on_click: {:close_help}
                )
              ]
            end
          ]

          # End list of children for column
        end
      end

    rendered_dialog
  end

  # --- Placeholder Hint Function ---
  defp get_hints_for(_focused_component_id), do: []

  # Correct arity for Application behaviour
  @impl Raxol.Core.Runtime.Application
  def handle_event(_event) do
    # State is managed by Dispatcher, just return commands
    []
  end

  # Correct arity for Application behaviour
  @impl Raxol.Core.Runtime.Application
  def handle_message(_msg, state), do: {state, []}

  # Correct arity for Application behaviour
  @impl Raxol.Core.Runtime.Application
  def handle_tick(_tick) do
    # State is managed by Dispatcher, just return commands
    []
  end

  @impl Raxol.Core.Runtime.Application
  def subscriptions(_state), do: []

  @impl Raxol.Core.Runtime.Application
  def terminate(_reason, _state), do: :ok
end
