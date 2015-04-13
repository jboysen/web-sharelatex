define [
	"base"
], (App) ->
	# We create and provide this as service so that we can access the global ide
	# from within other parts of the angular app.
	App.factory "commandRunner", ($http, $timeout, ide) ->
		ide.socket.on "clsiOutput", (message) ->
			session_id = message.header?.session
			return if !session_id?
			
			run = commandRunner.INPROGRESS_RUNS[session_id]
			return if !run?
			
			if message.msg_type == "system_status" and message.content.status == "starting_run"
				run.inited = true
				ide.$scope.$apply()
			else if message.msg_type == "command_exited"
				run.exitCode = message.content.exitCode
				commandRunner._parseErrors(run)
				commandRunner._displayErrors(run)
			else
				output = commandRunner._parseOutputMessage(message)
				if output?
					output = commandRunner._filterOutputMessage(output)
					run.output.push output
					ide.$scope.$apply()
		
		commandRunner =
			INPROGRESS_RUNS: {}
			
			run: (options) ->
				run = @_createNewRun()

				initing = $timeout () ->
					# Only show initing message after 2 seconds of delay
					run.stillIniting = true
				, 2000
				run.running = true
				run.uncompiled = false
				
				url = "/project/#{ide.$scope.project_id}/compile"
				options._csrf = window.csrfToken
				options.session_id = run.session_id
				$http
					.post(url, options)
					.success (data) =>
						$timeout.cancel(initing)
						run.running = false
						run.stopping = false
						if data?.status == "timedout"
							run.timedout = true
						@_clearRun(run)
					.error () =>
						$timeout.cancel(initing)
						run.running = false
						run.stopping = false
						run.error = true
						@_clearRun(run)

				return run
			
			stop: (run) ->
				url = "/project/#{_ide.$scope.project_id}/compile/#{run.session_id}/stop"
				run.stopping = true
				$http
					.post(url, {
						_csrf: window.csrfToken
					})
					.error () ->
						run.stopping = false
		
			_createNewRun: () ->
				session_id = Math.random().toString().slice(2)
				run = @INPROGRESS_RUNS[session_id] = {
					output: []
					running: false
					error: false
					timedout: false
					session_id: session_id
					stillIniting: false
					inited: false
					stopping: false
					exitCode: null
					parsedErrors: []
				}
				return run
			
			_clearRun: (run) ->
				# Once a run has completed, we don't need to keep it hanging
				# around in our memory for appending messages to it.
				# Add a short delay to ensure that all real time messages
				# have been flushed (this delay can be removed if there is a more
				# reliable way of ensuring we have all the real-time content)
				setTimeout () =>
					delete @INPROGRESS_RUNS[run.session_id]
				, 5000
			
			_parseOutputMessage: (message) ->
				if message.msg_type == "stream"
					output = {
						output_type: message.content.name # 'stdout' or 'stderr'
						text: message.content.text
						msg_id: parseInt(message.header.msg_id, 10)
					}
				else if message.msg_type == "file_modified"
					path = message.content.data['text/path']
					output = {
						output_type: "file"
						url: "/project/#{ide.$scope.project_id}/output/#{path}?cache_bust=#{Date.now()}"
						file_type: "unknown"
						path: path
						ignore: @_shouldIgnorePath(path)
						msg_id: parseInt(message.header.msg_id, 10)
					}
					parts = path.split(".")
					if parts.length == 1
						extension = null
					else
						extension = parts[parts.length - 1].toLowerCase()
					output.extension = extension
					if extension in ["png", "jpg", "jpeg", "svg", "gif"]
						output.file_type = "image"
					else if extension in ["pdf"]
						output.file_type = "pdf"
					else if extension in ["rout"]
						output.file_type = "text"
				else
					output = null
				return output

			_shouldIgnorePath: (path) ->
				return true if path.match(/\.pyc$/)
				return false

			_filterOutputMessage: (output) ->
				if output.output_type == 'stderr'
					# strip call stack from R error output
					output.text = output.text.replace /Calls: source -> withVisible -> eval -> eval.*\n/, ''
				return output

			_parseErrors: (run) ->
				stderr = ""
				for output in run.output
					if output.output_type == "stderr"
						stderr += output.text
				stderr = stderr.replace /ImportError: No module named ([^ ]*)/g, (match, packageName) ->
					run.parsedErrors.push {
						type: "missing_package"
						package: packageName
						language: "python"
					}
					return match
				stderr = stderr.replace /there is no package called ['‘](.*)[’']/, (match, packageName) ->
					run.parsedErrors.push {
						type: "missing_package"
						package: packageName
						language: "R"
					}
					return "DONE"
				stderr = stderr.replace ///^
					(Error.*(\(from\s\S+\.[rR]\#\d+\))?.*) # first line has "Error in foo (from file.R#8) blah"
					\n
					((\s*\d+:.*(\s at\s\S+\.[rR]\#\d+)?\n|\s.*\n)*) # stack frames (repeated) have "1: foo() at lib.R#2"
				///m, (match, error, line, stack) ->
					# the top-level error
					parsedError = {
						type: "runtime_error"
						# strip any default error text coming from wrapper script
						message: error.replace(/^Error in eval\(expr, envir, enclos\)/,'Error').replace(/\(from (\S+\.[rR])#(\d+)\)/, '')
						language: "R"
					}
					result = error.match /\(from (\S+\.[rR])#(\d+)\)/
					if result?
						fileName = result[1]
						lineNumber = parseInt result[2], 10
						parsedError.file = fileName
						parsedError.line = lineNumber
					# parse the stack lines (if any)
					stackLines = stack?.replace(/\s?\n^\s+/mg,' ').replace(/\n+$/, '').split '\n'
					if stackLines?
						stackFrames = []
						seenLocation = false # whether we've got a file/line yet
						for s, i in stackLines
							frame = { message: s.replace(/at (\S+\.[rR])#(\d+)/, '') }
							s.replace /at (\S+\.[rR])#(\d+)/, (match, fileName, lineNumber) ->
								frame.file = fileName
								frame.line = parseInt lineNumber, 10
								seenLocation = true
							stackFrames.push frame if seenLocation
						# add the stack frame to the error object
						parsedError.stack = stackFrames if stackFrames.length
						run.parsedErrors.push parsedError

			_displayErrors: (run) ->
				$scope = ide.$scope
				$scope.pdf.logEntryAnnotations = {}

				addError = (error, message = error.message, type = "error") ->
					return unless error.file?
					entity = ide.fileTreeManager.findEntityByPath(error.file)
					if entity?
						$scope.pdf.logEntryAnnotations[entity.id] ||= []
						$scope.pdf.logEntryAnnotations[entity.id].push {
							row: error.line-1
							type: type
							text: message
						}

				formatStackTrace = (error, depth) ->
					formatLine = (frame, i, j) ->
						if i == j then "*" + frame.message else frame.message
					error.message + "\n" + (formatLine(s, i, depth) for s, i in error.stack).join("\n")

				for error in run.parsedErrors
					if error.stack?
						status = "error"
						addError error, formatStackTrace(error, -1), status
						for frame, i in error.stack
							addError frame, formatStackTrace(error, i), status
							status = "warning" if frame.line?
					else
						addError error

				$scope.$evalAsync()


		return commandRunner
