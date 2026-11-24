import Foundation
import KirieServices

// Entry point for the `kirie` command-line tool. All output on stdout is JSON; progress goes to stderr.
let exitCode = await CommandLineTool.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(exitCode)
