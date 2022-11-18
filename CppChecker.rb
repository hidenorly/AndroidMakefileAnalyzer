#!/usr/bin/env ruby

# Copyright 2022 hidenory
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'fileutils'
require 'optparse'
require 'shellwords'
require 'json'
require 'rexml/document'
require_relative 'FileUtil'
require_relative 'StrUtil'
require_relative 'TaskManager'
require_relative 'ExecUtil'
require_relative 'Reporter'

class RepoUtil
	DEF_MANIFESTFILE = "manifest.xml"
	DEF_MANIFESTFILE_DIRS = [
		"/.repo/",
		"/.repo/manifests/"
	]

	def self.getAvailableManifestPath(basePath, manifestFilename)
		DEF_MANIFESTFILE_DIRS.each do |aDir|
			path = basePath + aDir.to_s + manifestFilename
			if FileTest.exist?(path) then
				return path
			end
		end
		return nil
	end

	def self.getPathesFromManifestSub(basePath, manifestFilename, pathes, pathFilter, groupFilter)
		manifestPath = getAvailableManifestPath(basePath, manifestFilename)
		if manifestPath && FileTest.exist?(manifestPath) then
			doc = REXML::Document.new(open(manifestPath))
			doc.elements.each("manifest/include[@name]") do |anElement|
				getPathesFromManifestSub(basePath, anElement.attributes["name"], pathes, pathFilter, groupFilter)
			end
			doc.elements.each("manifest/project[@path]") do |anElement|
				theGitPath = anElement.attributes["path"].to_s
				if pathFilter.empty? || ( !pathFilter.to_s.empty? && theGitPath.match( pathFilter.to_s ) ) then
					theGroups = anElement.attributes["groups"].to_s
					if theGroups.empty? || groupFilter.empty? || ( !groupFilter.to_s.empty? && theGroups.match( groupFilter.to_s ) ) then
						pathes << "#{basePath}/#{theGitPath}"
					end
				end
			end
		end
	end

	def self.getPathesFromManifest(basePath, pathFilter="", groupFilter="")
		pathes = []
		getPathesFromManifestSub(basePath, DEF_MANIFESTFILE, pathes, pathFilter, groupFilter)

		return pathes
	end
end

class AndroidUtil
	DEF_ANDROID_ROOT=[
	    "/system/",
	    "/frameworks/",
	    "/device/",
	    "/vendor/",
	    "/packages/",
	    "/external/",
	    "/hardware/",
	    "/build/",
	    "/compatibility/",
	    "/bootable/",
	    "/bionic/",
	    "/art/",
	    "/dalvik/",
	    "/cts/",
	    "/developers/",
	    "/development/",
	    "/kernel/",
	    "/libnativehelper/",
	    "/pdk/",
	    "/sdk/",
	    "/prebuilts/",
	    "/platform_testing/",
	    "/test/",
	    "/toolchain/",
	    "/tools/"
	]

	def self.getAndroidRootPath(path)
		result = ""
		DEF_ANDROID_ROOT.each do |aPath|
			pos = path.index(aPath)
			if pos then
				result = path.slice(0, pos)
				break
			end
		end
		return result
	end
end


class CppChecker
	DEF_CPPCHECK = "cppcheck"
	DEF_CPPCHECK_TEMPLATE = "[{file}],[{line}],[{severity}],[{id}],[{message}]"
	DEF_EXEC_TIMEOUT = 60*3

	def initialize(targetPath, optEnable, timeOut=DEF_EXEC_TIMEOUT)
		@targetPath = File.expand_path(targetPath)
		@optEnable = optEnable
		@timeOut = timeOut
	end

	def _parseResult(aLine)
		result = {}

		_result = aLine.split("],[")
		if _result.length >= 5 then
			found = true
			result["filename"] = _result[0].slice(1, _result[0].length)
			result["line"] = _result[1]
			result["severity"] = _result[2]
			result["id"] = _result[3]
			_result.shift(4)
			_result = _result.join("],[")
			result["message"] = _result.slice(0, _result.length-1)
		end
		return result
	end

	def _filterFiles(files)
		results = []
		files.each do |aFile|
			results << aFile if ( aFile.end_with?(".cpp") || aFile.end_with?(".c") || aFile.end_with?(".cc") || aFile.end_with?(".h") || aFile.end_with?(".hpp") || aFile.end_with?(".cxx") || aFile.end_with?(".") ) && File.exist?(aFile)
		end
		return results
	end


	def execute(targetFiles=["."])
		results = []

		targetFiles = _filterFiles(targetFiles)

		exec_cmd = "#{DEF_CPPCHECK} --quiet --template=\"#{DEF_CPPCHECK_TEMPLATE}\""
		exec_cmd = exec_cmd + " --enable=#{@optEnable}" if @optEnable && !@optEnable.empty?
		exec_cmd = exec_cmd + " #{targetFiles.join(" ")}"

		resultLines = ExecUtil.getExecResultEachLineWithTimeout(exec_cmd, @targetPath, @timeOut, true, true)

		resultLines.each do |aLine|
			_result = _parseResult(aLine)
			results << _result if !_result.empty?
		end

		return results
	end
end


class GitUtil
	def self.isGitDirectory(gitPath)
		return File.directory?("#{gitPath}/.git")
	end

	def self.getHeadCommitId(gitPath)
		exec_cmd = "git show --pretty=\"%h\" HEAD"
		results = ExecUtil.getExecResultEachLine(exec_cmd, gitPath, false, true)
		return !results.empty? ? results[0] : nil
	end

	def self.getFilesWithGitOpts(gitPath, gitOpt = "")
		exec_cmd = "git log --name-only --pretty=\"\" #{gitOpt ? gitOpt : ""} | sort -u"
		return ExecUtil.getExecResultEachLine(exec_cmd, gitPath, false, true, true)
	end

	def self._getValue(aLine, key)
		result = nil
		aLine = aLine.to_s
		pos = aLine.index(key)
		if pos then
			result = aLine.slice( pos+key.length, aLine.length )
			result.strip!
		end
		return result
	end

	def self._getValueFromLines(lines, key)
		lines.each do |aLine|
			result = _getValue(aLine, key)
			return result if result
		end
		return ""
	end

	def self.gitBlame(gitPath, filename, line)
		results = {}
		exec_cmd = "git blame -p #{filename} -L #{line},#{line}"
		result = ExecUtil.getExecResultEachLine(exec_cmd, gitPath, false, true, true)
		if !result.empty? then
			results[:commitId] = result[0].split(" ")[0]
			results[:author] = _getValueFromLines(result, "author")
			results[:authorMail] = _getValueFromLines(result, "author-mail")
			results[:theLine] = result.last.to_s.strip
		end
		return results
	end
end


class CppCheckExecutor < TaskAsync
	def initialize(resultCollector, path, options)
		super("CppCheckExecutor #{path}")
		@resultCollector = resultCollector
		@path = path.to_s
		@options = options
		@cppCheck = CppChecker.new( path, options[:optEnable] )
	end

	def enhanceResult(results)
		_results = []

		results.each do | aResult |
			theResult = {}
			theResult = GitUtil.gitBlame( @path, aResult["filename"], aResult["line"] ) if !aResult["filename"].empty? && !aResult["line"].empty?
			if theResult.empty? then
				_results << aResult
			else 
				_results << aResult.merge( theResult )
			end
		end

		return _results
	end

	def execute
		results = {}
		isGitDirectory = GitUtil.isGitDirectory(@path)
		results[:name] = FileUtil.getFilenameFromPath(@path)
		results[:path] = @path.slice( AndroidUtil.getAndroidRootPath(@path).to_s.length, @path.length )
		results[:results] = @cppCheck.execute( isGitDirectory ? @options[:gitOpt] ? GitUtil.getFilesWithGitOpts( @path, @options[:gitOpt] ) : ["."] : ["."] )
		results[:results] = enhanceResult( results[:results] ) if isGitDirectory
		@resultCollector.onResult(@path, results) if @resultCollector && !results[:results].empty?
		_doneTask()
	end
end



#---- main --------------------------
options = {
	:verbose => false,
	:reportOutPath => nil,
	:mode => "all",
	:gitOpt => nil,
	:exceptFiles => "test",
	:summarySection => "moduleName|path|error|warning|performance|style|information",
	:detailSection => nil,
	:optEnable => nil, # subset of "warning,style,performance,portability,information,unusedFunction,missingInclude" or "all"
	:pathFilter => nil,
	:numOfThreads => TaskManagerAsync.getNumberOfProcessor()
}

reporter = MarkdownReporter
resultCollector = ResultCollectorHash.new()

opt_parser = OptionParser.new do |opts|
	opts.banner = "Usage: usage ANDROID_HOME"

	opts.on("-m", "--mode=", "Specify report mode all or summary or detail default:#{options[:mode]}") do |mode|
		mode = mode.to_s.downcase
		case mode
		when "summary"
			options[:mode] = "summary"
		when "all"
			options[:mode] = "all"
		when "detail"
			options[:mode] = "detail"
		end
	end

	opts.on("-p", "--reportOutPath=", "Specify report output folder if you want to report out as file") do |reportOutPath|
		options[:reportOutPath] = reportOutPath
	end

	opts.on("-r", "--reportFormat=", "Specify report format markdown|csv|xml (default:#{options[:reportFormat]})") do |reportFormat|
		case reportFormat.to_s.downcase
		when "markdown"
			reporter = MarkdownReporter
		when "csv"
			reporter = CsvReporter
		when "xml"
			reporter = XmlReporter
		end
	end

	opts.on("-g", "--gitOpt=", "Specify option for git (default:options[:gitOpt]") do |gitOpt|
		options[:gitOpt] = gitOpt
	end

	opts.on("-e", "--optEnable=", "Specify option --enable for cppcheck (default:options[:optEnable]") do |optEnable|
		options[:optEnable] = optEnable
	end

	opts.on("", "--summarySection=", "Specify summary sections with | separator (default:#{options[:summarySection]})(\"\" means everything)") do |summarySection|
		options[:summarySection] = summarySection
	end

	opts.on("", "--detailSection=", "Specify detail sections with | separator (default:#{options[:detailSection]})(\"\" means everything)") do |detailSection|
		options[:detailSection] = detailSection
	end

	opts.on("-f", "--pathFilter=", "Specify file path filter (default:#{options[:pathFilter]})(\"\" means everything)") do |pathFilter|
		options[:pathFilter] = pathFilter
	end

	opts.on("-j", "--numOfThreads=", "Specify number of threads to analyze (default:#{options[:numOfThreads]})") do |numOfThreads|
		numOfThreads = numOfThreads.to_i
		options[:numOfThreads] = numOfThreads if numOfThreads
	end

	opts.on("", "--verbose", "Enable verbose status output") do
		options[:verbose] = true
	end
end.parse!

componentPaths = []

if ARGV.length < 1 then
	puts opt_parser
	exit(-1)
else
	isDirectory = FileTest.directory?(ARGV[0])
	if !isDirectory  then
		puts ARGV[0] + " is not found"
		exit(-1)
	else
		componentPaths = RepoUtil.getPathesFromManifest( ARGV[0] )
		if componentPaths.empty? then
			ARGV.each do |aPath|
				componentPaths << aPath if FileTest.directory?(aPath)
			end
		end
	end
end

if options[:pathFilter] then
	_componentPaths = []
	componentPaths.each do | aComponentPath |
		_componentPaths << aComponentPath if aComponentPath.include?( options[:pathFilter] ) || aComponentPath.match( options[:pathFilter] )
	end
	componentPaths = _componentPaths
end


taskMan = ThreadPool.new( options[:numOfThreads].to_i )
componentPaths.each do | aPath |
	taskMan.addTask( CppCheckExecutor.new( resultCollector, aPath, options ) )
end
taskMan.executeAll()
taskMan.finalize()

_result = resultCollector.getResult()
_result = _result.sort


FileUtil.ensureDirectory(options[:reportOutPath])

# create summary report
if options[:mode] == "summary" || options[:mode] == "all"
	results = []
	_result.each do |path, theResult|
		theSummary = {}
		theResult[:results] = theResult[:results].uniq
		theResult[:results].each do |aResult|
			if aResult.has_key?("severity") then
				severity = aResult["severity"]
				theSummary[severity] = 0 if !theSummary.has_key?(severity)
				theSummary[severity] = theSummary[severity] + 1
			end
		end
		if !theSummary.empty? then
			result = {}
			result["moduleName"] = theResult[:name]
			result["path"] = theResult[:path]
			result = result.merge(theSummary)
			results << result
		end
	end

	SUMMARY_KEYS = ["error", "warning", "performance", "style", "information"]
	results.sort! do |a, b|
		vecA = []
		vecB = []
		SUMMARY_KEYS.each do |key|
			if a.has_key?(key) && b.has_key?(key) then
				vecA << -a[key].to_i
				vecB << -b[key].to_i
			end
		end
		vecA <=> vecB
	end

	_reporter = reporter.new( options[:reportOutPath] ? "#{options[:reportOutPath]}/summary" : options[:reportOutPath] )
	_reporter.report( results, options[:summarySection] )
	_reporter.close()
end


# create per-component report
if options[:mode] == "detail" || options[:mode] == "all" then
	_result.each do |moduleName, theResult|
		results = theResult[:results]

		#results = results.sort_by { |h| h.values_at("filename", "line") }
		tmp = {}
		results.each do |aResult|
			tmp[ aResult["filename"] ] = [] if !tmp.has_key?( aResult["filename"] )
			tmp[ aResult["filename"] ] << aResult
		end
		tmp.each do | filename, aResult |
			aResult = aResult.uniq
			tmp[filename] = aResult.sort do |a, b|
				a["line"].to_i <=> b["line"].to_i
			end
		end
		results = []
		tmp.each do | filename, aResults |
			aResults.each do | aResult |
				results << aResult
			end
		end

		_reporter = reporter.new( options[:reportOutPath] ? "#{options[:reportOutPath]}/#{theResult[:name]}" : options[:reportOutPath] )
		_reporter.report( results, options[:detailSection] )
		_reporter.close()
	end
end