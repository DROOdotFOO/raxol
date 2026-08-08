import * as vscode from 'vscode';

export function activate(context: vscode.ExtensionContext) {
  // Register Raxol commands
  registerCommands(context);

  // Set up file watchers for Raxol-specific files
  setupFileWatchers(context);
}

export function deactivate() {
  // Nothing to tear down: the commands run in a terminal the user owns.
}

function registerCommands(context: vscode.ExtensionContext) {
  // Generate Component
  context.subscriptions.push(
    vscode.commands.registerCommand('raxol.generateComponent', async (uri) => {
      const componentName = await vscode.window.showInputBox({
        prompt: 'Enter component name',
        placeHolder: 'MyComponent'
      });

      if (componentName) {
        const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
        if (workspaceFolder) {
          const terminal = vscode.window.createTerminal('Raxol Generator');
          terminal.sendText(`cd "${workspaceFolder.uri.fsPath}"`);
          terminal.sendText(`mix raxol.gen.component ${componentName}`);
          terminal.show();
        }
      }
    })
  );

  // Open Component Playground
  context.subscriptions.push(
    vscode.commands.registerCommand('raxol.openPlayground', () => {
      const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
      if (workspaceFolder) {
        const terminal = vscode.window.createTerminal('Raxol Playground');
        terminal.sendText(`cd "${workspaceFolder.uri.fsPath}"`);
        terminal.sendText('mix raxol.playground');
        terminal.show();
      }
    })
  );
}

function setupFileWatchers(context: vscode.ExtensionContext) {
  // Watch for new Raxol component files
  const componentWatcher = vscode.workspace.createFileSystemWatcher(
    '**/lib/**/components/**/*.ex'
  );

  componentWatcher.onDidCreate((uri) => {
    // Automatically add component boilerplate if file is empty
    vscode.workspace.openTextDocument(uri).then((doc) => {
      if (doc.getText().trim() === '') {
        suggestComponentTemplate(doc);
      }
    });
  });

  context.subscriptions.push(componentWatcher);
}

async function suggestComponentTemplate(document: vscode.TextDocument) {
  const action = await vscode.window.showInformationMessage(
    'Generate Raxol component boilerplate?',
    'Yes', 'No'
  );

  if (action === 'Yes') {
    const fileName = document.fileName.split('/').pop()?.replace('.ex', '') || 'Component';
    const componentName = pascalCase(fileName);
    
    const template = generateComponentTemplate(componentName);
    
    const edit = new vscode.WorkspaceEdit();
    edit.insert(document.uri, new vscode.Position(0, 0), template);
    vscode.workspace.applyEdit(edit);
  }
}

function generateComponentTemplate(componentName: string): string {
  return `defmodule ${componentName} do
  @moduledoc """
  ${componentName} component.
  """

  use Raxol.UI.Components.Base.Component

  def init(props) do
    Map.merge(%{}, props)
  end

  def mount(state) do
    {state, []}
  end

  def update(message, state) do
    # Handle component messages here
    state
  end

  def render(state, context) do
    # Render component UI here
    text("${componentName}")
  end

  def handle_event(event, state, context) do
    # Handle UI events here
    {state, []}
  end
end
`;
}

function pascalCase(str: string): string {
  return str
    .split('_')
    .map(word => word.charAt(0).toUpperCase() + word.slice(1).toLowerCase())
    .join('');
}