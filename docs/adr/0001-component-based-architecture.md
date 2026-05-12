# ADR-0001: Component-Based Architecture

## Status

Accepted -- Revised

> **Note:** The code examples below reflect the original design proposal. The implemented API uses `Raxol.UI.Components.Base.Component` -- see [Custom Components](../cookbook/CUSTOM_COMPONENTS.md) for current usage.

## Context

Building terminal UIs with raw cursor movements and ANSI escape codes is tedious and error-prone. It doesn't scale to complex interfaces. Web frameworks like React and Phoenix LiveView have shown that declarative, component-based UI programming is more productive and maintainable than imperative approaches.

## Decision

Raxol uses a component-based architecture modeled after React and Phoenix LiveView.

The key pieces:

1. **Declarative components** -- UI is a function of state
2. **Virtual terminal** -- an in-memory representation of the screen, diffed before rendering
3. **Lifecycle hooks** -- mount, update, render, unmount
4. **Props and state** -- clear separation between component inputs and internal state
5. **Unified event system** -- keyboard, mouse, and custom events all handled the same way

## Implementation

### Component Structure

```elixir
defmodule MyComponent do
  use Raxol.UI.Components.Base.Component

  def init(props) do
    Map.merge(%{count: 0}, props)
  end

  def mount(state) do
    {state, []}
  end

  def update(:increment, state) do
    %{state | count: state.count + 1}
  end

  def render(state, _context) do
    row do
      button(label: "-", on_click: :decrement)
      text("Count: #{state.count}")
      button(label: "+", on_click: :increment)
    end
  end

  def handle_event({:click, :increment}, state, _context) do
    {update(:increment, state), []}
  end
end
```

### Virtual Terminal Benefits

- Only re-renders changed portions of the screen
- Components are testable without an actual terminal
- Same code works in terminal and web contexts

## Consequences

### Positive

- Familiar model for anyone coming from web development
- Components are reusable and shareable
- Clear separation of concerns
- Easy to unit test

### Negative

- Adds a learning curve for the component model
- Virtual terminal introduces abstraction overhead
- Maintaining virtual state uses more memory

### Mitigation

- EmulatorLite bypasses GenServer overhead for performance-critical paths
- Efficient diff algorithms and buffer pooling keep memory in check

## Metrics

- Component render time: < 1ms typical
- Memory per component: < 1KB for simple components
- Target onboarding time: 5 minutes to first component

## References

- React Component Model: https://react.dev/learn/thinking-in-react
- Phoenix LiveView: https://hexdocs.pm/phoenix_live_view
- Elm Architecture: https://guide.elm-lang.org/architecture/
