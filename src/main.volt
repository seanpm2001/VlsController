// Copyright 2018, Bernard Helyer.
// SPDX-License-Identifier: BSL-1.0
module main;

import core.rt.thread;
import lsp = vls.lsp;
import watt = [watt.path, watt.io, watt.io.file, watt.text.string,
	watt.process.spawn, watt.process.environment];
import json = watt.json;
import vlsc.util.aio;
import inputThread = vlsc.inputThread;
import streams = watt.io.streams;

import diagnostics = vlsc.diagnostics;

fn main(args: string[]) i32
{
	chdirToExtensionDirectory();
	loop();
	return 0;
}

//! Change directory to the extension directory.
fn chdirToExtensionDirectory()
{
	watt.chdir(watt.dirName(watt.getExecFile()));
}

//! Launch the language server process.
fn spawnVls() watt.Pid
{
	return watt.spawnProcess("vls.exe", null);
}

//! Spawn a language server and wait for it to exit cleanly.
fn loop()
{
	t := vrt_thread_start_fn(inputThread.threadFunction);
	pool := new AsyncProcessPool();
	scope (exit) pool.cleanup();
	vls: AsyncProcess;
	buildServer: AsyncProcess;

	retval: u32 = 1;

	// TODO: Make this cleaner, not duplicated nonsense

	fn vlsReport(process: AsyncProcess, reason: AsyncProcessPool.InterruptReason)
	{
		if (reason == AsyncProcessPool.InterruptReason.ProcessComplete) {
			if (process.closedRetval == 0) {
				retval = process.closedRetval;
			} else {
				watt.error.writeln("VlsController: vls crashed, relaunching vls process.");
				watt.error.flush();
				vls = pool.respawn(process, "vls.exe", null);
			}
		} else if (reason == AsyncProcessPool.InterruptReason.ReadComplete) {
			str := skipHeaders(process.readResult());
			if (str is null) {
				return;
			}
			if (watt.indexOf(str, "textDocument/publishDiagnostics") > 0) {
				ro := new lsp.RequestObject(str);
				if (ro.methodName == "textDocument/publishDiagnostics") {
					uri := lsp.getStringKey(ro.params, "uri");
					if (uri !is null) {
						diagnostics.emitLanguageServerDiagnostic(uri, str);
						return;
					}
				}
			}
			lsp.send(str);
		}
	}

	fn buildReport(process: AsyncProcess, reason: AsyncProcessPool.InterruptReason)
	{
		if (reason == AsyncProcessPool.InterruptReason.ProcessComplete) {
			watt.error.writeln("VlsController: build server crashed, relaunching process.");
			watt.error.flush();
			vls = pool.respawn(process, "VlsBuildServer.exe", null);
		} else if (reason == AsyncProcessPool.InterruptReason.ReadComplete) {
			str := skipHeaders(process.readResult());
			if (str is null) {
				return;
			}
			ro := new lsp.RequestObject(str);
			handleBuildServerRequest(ro);
		}
	}

	vls = pool.spawn(vlsReport, "vls.exe", null);
	buildServer = pool.spawn(buildReport, "VlsBuildServer.exe", null); 

	do {
		message: lsp.LspMessage;
		if (inputThread.getMessage(out message)) {
			ro := new lsp.RequestObject(message.content);
			if (ro.isBuildMessage()) {
				lsp.send(message.content, buildServer);
			} else {
				lsp.send(message.content, vls);
			}
		}
		pool.wait(ms:10);
	} while (retval != 0);
}

fn handleBuildServerRequest(ro: lsp.RequestObject)
{
	switch (ro.methodName) {
	case "textDocument/publishDiagnostics":
		uri := lsp.getStringKey(ro.params, "uri");
		if (uri !is null) {
			buildTag := lsp.getStringKey(ro.params, "buildTag");
			diagnostics.emitBuildServerDiagnostic(uri, buildTag, ro.originalText);
			if (buildTag !is null) {
				lsp.send(lsp.buildShowMessage(lsp.MessageType.Error, new "Build failure: ${buildTag}"));
			}
		}
		break;
	case "vls/buildSuccess":
		buildTag := lsp.getStringKey(ro.params, "buildTag");
		if (buildTag !is null) {
			diagnostics.clearBuildTag(buildTag);
		}
		lsp.send(lsp.buildShowMessage(lsp.MessageType.Info, new "Build success: ${buildTag}"));
		break;
	default:
		break;
	}
}

fn isBuildMessage(ro: lsp.RequestObject) bool
{
	if (ro.methodName != "workspace/executeCommand") {
		return false;
	}
	command := lsp.getStringKey(ro.params, "command");
	if (command is null) {
		return false;
	}
	switch (command) {
	case "vls.buildProject":
		return true;
	default:
		return false;
	}
}

fn skipHeaders(str: string) string
{
	index := watt.indexOf(str, "{");
	if (index == -1) {
		return null;
	}
	return str[index .. $];
}
