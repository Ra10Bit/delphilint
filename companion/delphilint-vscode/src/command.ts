/*
 * DelphiLint VSCode
 * Copyright (C) 2024 Integrated Application Development
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */
import * as vscode from "vscode";
import * as path from "path";
import * as fs from "fs";
import * as os from "os";
import { spawn } from "child_process";
import { LintServer, RequestAnalyze } from "./server";
import * as display from "./display";
import * as settings from "./settings";
import { LintError, NoAnalyzableFileError } from "./error";
import {
  getOrPromptActiveProject,
  getProjectOptions,
  promptActiveProject,
} from "./delphiProjectUtils";
import { LintStatusItem } from "./statusBar";

const DELPHI_SOURCE_EXTENSIONS = [".pas", ".dpk", ".dpr", ".inc"];

let inAnalysis: boolean = false;

export type ServerSupplier = () => Promise<LintServer>;
export type LoggerFunction = (msg: string) => void;

function isFileDelphiSource(filePath: string): boolean {
  return DELPHI_SOURCE_EXTENSIONS.includes(path.extname(filePath));
}

function isPathAbsolute(filePath: string): boolean {
  if (!filePath) {
    return false;
  }
  if (os.platform() === "linux") {
    return filePath.startsWith("/") || filePath.startsWith("~");
  } else {
    // Windows path check
    return /^[A-Za-z]:/.test(filePath) || filePath.startsWith("\\\\");
  }
}

function isFileInSearchPath(filePath: string, dprojPath: string): boolean {
  try {
    const normalizedFilePath = path.dirname(path.resolve(filePath));
    const normalizedDprojPath = path.dirname(path.resolve(dprojPath));

    logDebug("Checking paths:", {
      originalFilePath: filePath,
      normalizedFilePath: normalizedFilePath,
      originalDprojPath: dprojPath,
      normalizedDprojPath: normalizedDprojPath,
    });

    // Check if file is directly under project directory
    if (normalizedFilePath.startsWith(normalizedDprojPath)) {
      logDebug("File is directly under project directory");
      return true;
    }

    const fileContent = fs.readFileSync(dprojPath, "utf8");
    const match = /<DCC_UnitSearchPath>(.*?)<\/DCC_UnitSearchPath>/s.exec(
      fileContent
    );

    if (!match) {
      logDebug("No DCC_UnitSearchPath found in project file");
      return false;
    }

    const searchPaths = match[1].split(";").filter((p) => p.trim());
    logDebug("Found search paths:", searchPaths);

    for (const searchPath of searchPaths) {
      if (!searchPath) {
        continue;
      }

      const fullSearchPath = path.isAbsolute(searchPath)
        ? searchPath
        : path.resolve(normalizedDprojPath, searchPath);

      const normalizedSearchPath = path.resolve(fullSearchPath);

      logDebug("Checking search path:", {
        original: searchPath,
        full: fullSearchPath,
        normalized: normalizedSearchPath,
      });

      if (normalizedFilePath.startsWith(normalizedSearchPath)) {
        logDebug("File found in search path:", normalizedSearchPath);
        return true;
      }
    }

    logDebug("File not found in any search path");
    return false;
  } catch (error) {
    display.showError(`Error in isFileInSearchPath: ${error}`);
    return false;
  }
}

function isFileInProject(
  filePath: string,
  baseDir: string,
  projectFile?: string
): boolean {
  if (projectFile) {
    return isFileInSearchPath(filePath, projectFile);
  }
  return path
    .normalize(filePath)
    .toLowerCase()
    .startsWith(path.normalize(baseDir).toLowerCase());
}

function getDefaultBaseDir(inputFiles: string[]): string {
  const workspaces = inputFiles
    .map((file) => vscode.workspace.getWorkspaceFolder(vscode.Uri.file(file)))
    .filter((dir) => dir) as vscode.WorkspaceFolder[];

  if (workspaces.length === 0) {
    throw new NoAnalyzableFileError(
      "There are no source files that are analyzable under an open workspace."
    );
  }

  const baseWorkspace = workspaces[0];

  if (workspaces.length > 1) {
    display.showInfo(
      `Files from multiple workspaces are open. Analyzing only files under ${baseWorkspace.name}.`
    );
  }

  return baseWorkspace.uri.fsPath;
}

function logDebug(message: string, data?: any) {
  const detailsStr = data ? `\n${JSON.stringify(data, null, 2)}` : "";
  const fullMessage = `${message}${detailsStr}`;

  // Log to both console and show popup
  console.log(fullMessage);
  vscode.window.showInformationMessage(fullMessage);
}

function constructInputFiles(
  inputFiles: string[],
  baseDir: string,
  projectFile?: string
): string[] | undefined {
  if (inputFiles.length === 0) {
    return undefined;
  }

  const sourceFiles = inputFiles.filter(
    (file) =>
      isFileDelphiSource(file) && isFileInProject(file, baseDir, projectFile)
  );

  if (sourceFiles.length > 0) {
    const result = projectFile ? [...sourceFiles, projectFile] : sourceFiles;

    logDebug("=== Input Files Paths ===", {
      baseDirectory: baseDir,
      projectFile: projectFile || "None",
      sourceFiles: result.map((file) => ({
        file: file,
      })),
    });

    return result;
  }
}

function adjustBaseDirIfNeeded(msg: RequestAnalyze): RequestAnalyze {
  // If there are no files, return original message
  if (!msg.inputFiles.length) {
    return msg;
  }

  // Get all file directories
  const fileDirs = msg.inputFiles
    .map((file) => path.dirname(path.resolve(file)))
    .map((dir) => dir.toLowerCase());

  const currentBaseDir = path.resolve(msg.baseDir).toLowerCase();

  // Check if any file is outside (above) the current base directory
  const needsAdjustment = fileDirs.some(
    (dir) => !dir.startsWith(currentBaseDir)
  );

  if (!needsAdjustment) {
    return msg;
  }

  // Find the common ancestor directory
  let commonDir = path.dirname(path.resolve(msg.inputFiles[0]));

  for (const fileDir of fileDirs) {
    while (
      !fileDir.startsWith(commonDir.toLowerCase()) &&
      commonDir.length > 3
    ) {
      commonDir = path.dirname(commonDir);
    }
  }

  logDebug("=== Base Directory Adjustment ===", {
    originalBaseDir: msg.baseDir,
    adjustedBaseDir: commonDir,
    reason: "Files found above original base directory",
  });

  // Return new message with adjusted base directory
  return {
    ...msg,
    baseDir: commonDir,
  };
}

async function doAnalyze(
  server: LintServer,
  issueCollection: vscode.DiagnosticCollection,
  statusUpdate: LoggerFunction,
  msg: RequestAnalyze
) {
  // Adjust base directory if needed
  const adjustedMsg = adjustBaseDirIfNeeded(msg);

  const sourceFiles = adjustedMsg.inputFiles.filter((file) =>
    isFileDelphiSource(file)
  );

  logDebug("=== Analysis Input Files ===", {
    baseDirectory: adjustedMsg.baseDir,
    totalFiles: adjustedMsg.inputFiles.length,
    sourceFiles: {
      count: sourceFiles.length,
      files: sourceFiles,
    },
    projectKey: adjustedMsg.projectKey,
    projectPropertiesPath: adjustedMsg.projectPropertiesPath,
    sonarHostUrl: adjustedMsg.sonarHostUrl,
    disabledRules: adjustedMsg.disabledRules,
    inputFiles: adjustedMsg.inputFiles,
  });

  const flagshipFile = path.basename(sourceFiles[0]);
  const otherSourceFilesMsg =
    sourceFiles.length > 1 ? ` + ${sourceFiles.length - 1} more` : "";
  const analyzingMsg = `Analyzing ${flagshipFile}${otherSourceFilesMsg}...`;
  statusUpdate(analyzingMsg);

  const issues = await server.analyze(adjustedMsg);

  for (const filePath of sourceFiles) {
    issueCollection.set(vscode.Uri.file(filePath), undefined);
  }

  display.showIssues(issues, issueCollection);

  const issueWord = issues.length === 1 ? "issue" : "issues";
  statusUpdate(`${issues.length} ${issueWord} found`);
}

type Configuration = {
  apiToken: string;
  sonarHostUrl: string;
  projectKey: string;
  baseDir: string;
  projectPropertiesPath: string;
};

function getDefaultConfiguration(): Configuration {
  return {
    apiToken: "",
    sonarHostUrl: "",
    projectKey: "",
    baseDir: "",
    projectPropertiesPath: "",
  };
}

async function retrieveEffectiveConfiguration(
  projectFile: string
): Promise<Configuration> {
  let config = getDefaultConfiguration();

  const projectOptions = getProjectOptions(projectFile);
  if (projectOptions) {
    config.baseDir = projectOptions.baseDir();
    config.projectPropertiesPath = projectOptions.projectPropertiesPath();
    if (projectOptions.connectedMode()) {
      config.sonarHostUrl = projectOptions.sonarHostUrl();
      config.projectKey = projectOptions.projectKey();
      console.log(settings.getSonarTokens());

      const sonarTokens = settings.getSonarTokens();

      config.apiToken =
        sonarTokens[projectOptions.sonarHostUrl()]?.[
          projectOptions.projectKey()
        ] ??
        sonarTokens[projectOptions.sonarHostUrl()]?.["*"] ??
        "";
    }
  } else {
    config.baseDir = path.dirname(projectFile);
  }

  return config;
}

async function selectProjectFile(
  statusItem: LintStatusItem
): Promise<string | null> {
  statusItem.setAction("Selecting project...");
  const projectChoice = await getOrPromptActiveProject();
  statusItem.setActiveProject(projectChoice);
  return projectChoice || null;
}

async function convertDofToDproj(dofPath: string): Promise<string | null> {
  const dof2dprojPath = path.join(settings.SETTINGS_DIR, "dof2dproj.exe");
  if (!fs.existsSync(dof2dprojPath)) {
    display.showError(
      `Conversion utility dof2dproj.exe not found at ${dof2dprojPath}`
    );
    return null;
  }
  const dprojPath = dofPath.replace(".dof", ".dproj");
  return new Promise((resolve) => {
    const process = spawn(dof2dprojPath, ["--force", `"${dofPath}"`], {
      shell: true,
    });
    process.on("error", () => {
      display.showError(
        `Failed to start conversion for ${path.basename(dofPath)}`
      );
      resolve(null);
    });
    process.on("exit", (code) => {
      if (code === 0) {
        if (fs.existsSync(dprojPath)) {
          resolve(dprojPath);
        } else {
          display.showError(
            `DPROJ file was not created after conversion of ${path.basename(
              dofPath
            )}`
          );
          resolve(null);
        }
      } else {
        display.showError(
          `Conversion failed for ${path.basename(dofPath)} (code: ${code})`
        );
        resolve(null);
      }
    });
  });
}

async function analyzeFiles(
  serverSupplier: ServerSupplier,
  issueCollection: vscode.DiagnosticCollection,
  files: string[],
  statusItem: LintStatusItem
) {
  inAnalysis = true;
  try {
    let projectFile = await selectProjectFile(statusItem);

    if (projectFile?.toLowerCase().endsWith(".dof")) {
      statusItem.setAction("Converting DOF to DPROJ...");
      const dprojPath = await convertDofToDproj(projectFile);
      if (dprojPath) {
        projectFile = dprojPath;
      }
    }

    let config;
    if (projectFile) {
      config = await retrieveEffectiveConfiguration(projectFile);
    } else {
      config = getDefaultConfiguration();
      config.baseDir = getDefaultBaseDir(files);
    }

    statusItem.setAction("Checking files...");
    const inputFiles = constructInputFiles(
      files,
      config.baseDir,
      projectFile ?? undefined
    );
    if (!inputFiles) {
      throw new NoAnalyzableFileError(
        "There are no selected Delphi files that are analyzable under the current project."
      );
    }

    statusItem.setAction("Starting server...");
    const server = await serverSupplier();

    statusItem.setAction("Initializing server...");
    await server.initialize({
      bdsPath: settings.getBdsPath(),
      apiToken: config.apiToken,
      compilerVersion: settings.getCompilerVersion(),
      sonarHostUrl: config.sonarHostUrl,
      sonarDelphiVersion: settings.getSonarDelphiVersion(),
    });

    statusItem.setAction("Analyzing...");
    await doAnalyze(server, issueCollection, statusItem.setAction, {
      baseDir: config.baseDir,
      inputFiles: inputFiles, // prevent DPROJ duplication
      // inputFiles: projectFile ? [...inputFiles, projectFile] : inputFiles,
      projectKey: config.projectKey,
      projectPropertiesPath: config.projectPropertiesPath,
      sonarHostUrl: config.sonarHostUrl,
      apiToken: config.apiToken,
      disabledRules:
        config.sonarHostUrl === "" && !settings.getUseDefaultRules()
          ? settings.getDisabledRules()
          : undefined,
    });
  } finally {
    inAnalysis = false;
  }
}

export async function analyzeThisFile(
  serverSupplier: ServerSupplier,
  issueCollection: vscode.DiagnosticCollection
) {
  const activeTextEditor = vscode.window.activeTextEditor;
  if (!activeTextEditor) {
    display.showError("There is no active file for DelphiLint to analyze.");
    return;
  }

  if (inAnalysis) {
    display.showError("A DelphiLint analysis is already in progress.");
    return;
  }

  const currentFileUri = activeTextEditor.document.uri;

  await display.getStatusItem().with(async (statusItem) => {
    try {
      statusItem.startProgress();

      await analyzeFiles(
        serverSupplier,
        issueCollection,
        [currentFileUri.fsPath],
        statusItem
      );
    } catch (err) {
      statusItem.setAction("Analysis failed");
      if (err instanceof LintError) {
        display.showError(err.message);
      } else if (err instanceof Error) {
        display.showError("Unexpected error: " + err.message);
      }
    } finally {
      statusItem.stopProgress();
    }
  });
}

export async function analyzeAllOpenFiles(
  serverSupplier: ServerSupplier,
  issueCollection: vscode.DiagnosticCollection
) {
  const uris = vscode.window.tabGroups.all.flatMap((group) =>
    group.tabs
      .map((tab) => {
        if (typeof tab.input === "object" && tab.input && "uri" in tab.input) {
          return tab.input.uri as vscode.Uri;
        } else {
          return undefined;
        }
      })
      .filter((tab) => tab !== undefined)
  );

  const openTextEditors = uris.map((uri) => uri.fsPath);

  if (openTextEditors.length === 0) {
    display.showError("There are no open files for DelphiLint to analyze.");
    return;
  }

  if (inAnalysis) {
    display.showError("A DelphiLint analysis is already in progress.");
    return;
  }

  await display.getStatusItem().with(async (statusItem) => {
    try {
      statusItem.startProgress();

      await analyzeFiles(
        serverSupplier,
        issueCollection,
        [...openTextEditors],
        statusItem
      );
    } catch (err) {
      statusItem.setAction("Analysis failed");
      if (err instanceof LintError) {
        display.showError(err.message);
      } else if (err instanceof Error) {
        display.showError("Unexpected error: " + err.message);
      }
    } finally {
      statusItem.stopProgress();
    }
  });
}

export async function chooseActiveProject() {
  const activeProject = await promptActiveProject();
  display.getStatusItem().with(async (resource) => {
    resource.setActiveProject(activeProject);
  });
}

export async function clearThisFile(
  issueCollection: vscode.DiagnosticCollection
) {
  const activeTextEditor = vscode.window.activeTextEditor;
  if (activeTextEditor) {
    issueCollection.set(activeTextEditor.document.uri, undefined);
  }
}
