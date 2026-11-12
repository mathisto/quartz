import * as vscode from "vscode";
import { execFile } from "child_process";
import * as path from "path";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from "vscode-languageclient/node";

let outputChannel: vscode.OutputChannel;
let client: LanguageClient | undefined;

function getCompilerPath(): string {
  const config = vscode.workspace.getConfiguration("quartz");
  const configuredPath = config.get<string>("compilerPath", "");
  if (configuredPath) {
    return configuredPath;
  }
  return "quartz";
}

function getQuakePath(): string {
  const config = vscode.workspace.getConfiguration("quartz");
  const configuredPath = config.get<string>("quakePath", "");
  if (configuredPath) {
    return configuredPath;
  }
  return "quake";
}

function formatDocument(
  document: vscode.TextDocument
): Promise<vscode.TextEdit[]> {
  return new Promise((resolve, reject) => {
    const compilerPath = getCompilerPath();
    const config = vscode.workspace.getConfiguration("quartz");
    const extraArgs = config.get<string[]>("formatArgs", []);

    const args = ["--format", ...extraArgs];
    const originalText = document.getText();

    const child = execFile(
      compilerPath,
      args,
      {
        timeout: 10000,
        maxBuffer: 1024 * 1024,
        cwd: path.dirname(document.uri.fsPath),
      },
      (error, stdout, stderr) => {
        if (error) {
          if (stderr) {
            outputChannel.appendLine(`quartz format error: ${stderr}`);
          }
          outputChannel.appendLine(
            `quartz format failed: ${error.message}`
          );
          resolve([]);
          return;
        }

        if (stdout && stdout !== originalText) {
          const fullRange = new vscode.Range(
            document.positionAt(0),
            document.positionAt(originalText.length)
          );
          resolve([vscode.TextEdit.replace(fullRange, stdout)]);
        } else {
          resolve([]);
        }
      }
    );

    if (child.stdin) {
      child.stdin.write(originalText);
      child.stdin.end();
    }
  });
}

function runInTerminal(name: string, command: string): void {
  const terminal = vscode.window.createTerminal(name);
  terminal.show();
  terminal.sendText(command);
}

function runCurrentFile(): void {
  const editor = vscode.window.activeTextEditor;
  if (!editor || editor.document.languageId !== "quartz") {
    vscode.window.showErrorMessage("No Quartz file is open");
    return;
  }

  const filePath = editor.document.uri.fsPath;
  const compilerPath = getCompilerPath();
  const llvmBin = "/opt/homebrew/opt/llvm/bin";

  // Compile to LLVM IR, then to object, then link and run
  runInTerminal(
    "Quartz Run",
    `${compilerPath} "${filePath}" | ${llvmBin}/llc -filetype=obj -o /tmp/qz_run.o && clang /tmp/qz_run.o -o /tmp/qz_run && /tmp/qz_run`
  );
}

function buildProject(): void {
  const quakePath = getQuakePath();
  runInTerminal("Quartz Build", `${quakePath} build`);
}

function runTests(): void {
  const quakePath = getQuakePath();
  runInTerminal("Quartz Test", `${quakePath} qspec`);
}

async function startLanguageClient(
  context: vscode.ExtensionContext
): Promise<void> {
  const compilerPath = getCompilerPath();

  const serverOptions: ServerOptions = {
    command: compilerPath,
    args: ["lsp"],
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "quartz" }],
    outputChannel,
  };

  client = new LanguageClient(
    "quartz-lsp",
    "Quartz Language Server",
    serverOptions,
    clientOptions
  );

  try {
    await client.start();
    outputChannel.appendLine("Quartz language server started");
  } catch (err) {
    outputChannel.appendLine(
      `Failed to start Quartz language server: ${err}`
    );
    client = undefined;
  }
}

export function activate(context: vscode.ExtensionContext): void {
  outputChannel = vscode.window.createOutputChannel("Quartz");

  // Start language server if enabled
  const config = vscode.workspace.getConfiguration("quartz");
  const lspEnabled = config.get<boolean>("lsp.enabled", true);
  if (lspEnabled) {
    startLanguageClient(context);
  }

  // Register document formatting provider (fallback when LSP is not active)
  const formatter = vscode.languages.registerDocumentFormattingEditProvider(
    { language: "quartz", scheme: "file" },
    {
      provideDocumentFormattingEdits(
        document: vscode.TextDocument
      ): Thenable<vscode.TextEdit[]> {
        return formatDocument(document);
      },
    }
  );
  context.subscriptions.push(formatter);

  // Register format-on-save
  const onSave = vscode.workspace.onWillSaveTextDocument((event) => {
    const saveConfig = vscode.workspace.getConfiguration("quartz");
    const formatOnSave = saveConfig.get<boolean>("formatOnSave", true);

    if (
      formatOnSave &&
      event.document.languageId === "quartz" &&
      event.reason === vscode.TextDocumentSaveReason.Manual
    ) {
      event.waitUntil(formatDocument(event.document));
    }
  });
  context.subscriptions.push(onSave);

  // Register commands
  context.subscriptions.push(
    vscode.commands.registerCommand("quartz.format", () => {
      const editor = vscode.window.activeTextEditor;
      if (editor && editor.document.languageId === "quartz") {
        vscode.commands.executeCommand("editor.action.formatDocument");
      }
    }),
    vscode.commands.registerCommand("quartz.run", runCurrentFile),
    vscode.commands.registerCommand("quartz.build", buildProject),
    vscode.commands.registerCommand("quartz.test", runTests)
  );

  outputChannel.appendLine("Quartz language support activated");
}

export async function deactivate(): Promise<void> {
  if (client) {
    await client.stop();
    client = undefined;
  }
  if (outputChannel) {
    outputChannel.dispose();
  }
}
