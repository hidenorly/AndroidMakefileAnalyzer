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
require 'rexml/document'
require_relative 'FileUtil'
require_relative 'ExecUtil'
require_relative 'TaskManager.rb'
require 'shellwords'

class XmlPerLibReporterParser
	def self.getListOfReportFiles(reportPath)
		return FileUtil.getRegExpFilteredFiles(reportPath, ".*\.xml$")
	end

	def self.getElements(result, doc, elementName)
		if !result.has_key?(elementName) then
			result[elementName] = []
		end
		if doc then
			doc.elements.each("xml/#{elementName}") do |anElement|
				theElement = anElement.text.strip
				result[elementName] << theElement if !theElement.empty?
			end
		end
		if result[elementName].length == 1 then
			result[elementName] = result[elementName][0]
		elsif result[elementName].empty? then
			result[elementName] = ""
		end
		return result
	end


	def self.getFilenameFromPathWithoutExt( path, ext=".xml" )
		path = FileUtil.getFilenameFromPath(path)
		pos = path.to_s.rindex(ext)
		path = pos ? path.slice(0, pos) : path
		return path
	end


	def self.getResult(xmlPath)
		result = {}

		if FileTest.exist?(xmlPath) then
			doc = REXML::Document.new("<xml>#{FileUtil.readFile(xmlPath).to_s}</xml>")
			result = getElements( result, doc, "version" )
			result = getElements( result, doc, "headers" )
			result = getElements( result, doc, "libs" )
		end

		return result, getFilenameFromPathWithoutExt(xmlPath)
	end
end


class AbiComplianceChecker
	DEF_ACC = "abi-compliance-checker"
	DEF_GCC_PATH = ENV["PATH_GCC"]
	DEF_EXEC_TIMEOUT = 60*3

	def initialize(libXmlPath1, libXmlPath2, reportOutPath, oldVer="", newVer="", timeOut=DEF_EXEC_TIMEOUT)
		@libXmlPath1 = File.expand_path(libXmlPath1)
		@libXmlPath2 = File.expand_path(libXmlPath2)
		@reportOutPath = reportOutPath
		@libName = XmlPerLibReporterParser.getFilenameFromPathWithoutExt(libXmlPath1)
		@oldVer = oldVer.to_s
		@newVer = newVer.to_s
		@timeOut = timeOut
	end

	SZ_BIN_COMPAT 	= "Binary compatibility: "
	SZ_SRC_COMPAT 	= "Source compatibility: "
	SZ_BIN_COMPAT2	= "Total binary compatibility problems: "
	SZ_SRC_COMPAT2	= "Total source compatibility problems: "
	SZ_WARNINGS		= ", warnings: "

	def parseResult(result, aLine)
		found = false
		if aLine.start_with?(SZ_BIN_COMPAT) then
			result[:binCompatibility] = aLine.slice(SZ_BIN_COMPAT.length, aLine.length-SZ_BIN_COMPAT.length-1).to_i
			found = true
		elsif aLine.start_with?(SZ_SRC_COMPAT) then
			result[:srcCompatibility] = aLine.slice(SZ_SRC_COMPAT.length, aLine.length-SZ_SRC_COMPAT.length-1).to_i
			found = true
		elsif aLine.start_with?(SZ_BIN_COMPAT2) then
			pos = aLine.index(",", SZ_BIN_COMPAT2.length)
			pos2 = aLine.index(SZ_WARNINGS, SZ_BIN_COMPAT2.length)
			if pos && pos2 then
				result[:binProblem] = aLine.slice(SZ_BIN_COMPAT2.length, aLine.length-pos).to_i
				result[:binWarning] = aLine.slice(pos2, aLine.length-pos2).to_i
				found = true
			end
		elsif aLine.start_with?(SZ_SRC_COMPAT2) then
			pos = aLine.index(",", SZ_SRC_COMPAT2.length)
			pos2 = aLine.index(SZ_WARNINGS, SZ_SRC_COMPAT2.length)
			if pos && pos2 then
				result[:srcProblem] = aLine.slice(SZ_SRC_COMPAT2.length, aLine.length-pos).to_i
				result[:srcWarning] = aLine.slice(pos2, aLine.length-pos2).to_i
				found = true
			end
		end
		return found
	end

	def execute
		result = {
			:libName=>@libName,
			:binCompatibility=>0, 
			:srcCompatibility=>0, 
			:binProblem=>0, 
			:binWarning=>0, 
			:srcProblem=>0, 
			:srcWarning=>0,
			:report=>""
		}

		exec_cmd = "#{DEF_ACC} -lib #{Shellwords.escape(@libName)} -old #{Shellwords.escape(@libXmlPath1)} -new #{Shellwords.escape(@libXmlPath2)}"
		exec_cmd = exec_cmd + " -v1 #{@oldVer}" if !@oldVer.empty?
		exec_cmd = exec_cmd + " -v2 #{@newVer}" if !@newVer.empty?
		exec_cmd = exec_cmd + " --gcc-path=#{Shellwords.escape(DEF_GCC_PATH)}" if DEF_GCC_PATH

		resultLines = ExecUtil.getExecResultEachLineWithTimeout(exec_cmd, @reportOutPath, @timeOut, false, true)

		found = false
		resultLines.each do |aLine|
			found = found | parseResult(result, aLine)
		end
		result[:report] = "#{@reportOutPath}/compat_reports/#{@libName}/#{@oldVer ? @oldVer : "X"}_to_#{@newVer ? @newVer : "Y"}/compat_report.html"

		return found ? result : nil
	end
end


class AbiComplianceCheckerExecutor < TaskAsync
	def initialize(resultCollector, libXmlPath1, libXmlPath2, reportOutPath, oldVer="", newVer="", timeOut)
		super("AbiComplianceCheckerTask #{libXmlPath1} #{libXmlPath2}")
		@resultCollector = resultCollector
		@lib = XmlPerLibReporterParser.getFilenameFromPathWithoutExt(libXmlPath1)
		@abiChecker = AbiComplianceChecker.new(libXmlPath1, libXmlPath2, reportOutPath, oldVer, newVer, timeOut)
	end

	def execute
		result = @abiChecker.execute()
		@resultCollector.onResult(@lib, result) if result && !result.empty?
		_doneTask()
	end

end

class Reporter
	def self.convertArray(data, key)
		result = []
		data.each do |aData|
			result << {key=>aData}
		end
		return result
	end

	def self.titleOut(title)
		puts title
	end

	def self.report(data)
		if data.length then
			keys = data[0]
			if keys.kind_of?(Hash) then
				_conv(keys, true, false, true)
			end

			data.each do |aData|
				_conv(aData)
			end
		end
	end

	def self._conv(aData, keyOutput=false, valOutput=true, firstLine=false)
		puts aData
	end
end

class MarkdownReporter < Reporter
	def self.titleOut(title)
		puts "\# #{title}"
		puts ""
	end

	def self.reportFilter(aLine)
		if aLine.is_a?(String) then
			aLine = "[#{FileUtil.getFilenameFromPath(aLine)}](#{aLine})" if aLine.start_with?("http://")
		end

		return aLine
	end

	def self._conv(aData, keyOutput=false, valOutput=true, firstLine=false)
		separator = "|"
		aLine = separator
		count = 0
		if aData.kind_of?(Enumerable) then
			if aData.kind_of?(Hash) then
				aData.each do |aKey,theVal|
					aLine = "#{aLine} #{aKey} #{separator}" if keyOutput
					aLine = "#{aLine} #{reportFilter(theVal)} #{separator}" if valOutput
					count = count + 1
				end
			elsif aData.kind_of?(Array) then
				aData.each do |theVal|
					aLine = "#{aLine} #{reportFilter(theVal)} #{separator}" if valOutput
					count = count + 1
				end
			end
			puts aLine
			if firstLine && count then
				aLine = "|"
				for i in 1..count do
					aLine = "#{aLine} :--- |"
				end
				puts aLine
			end
		else
			puts "#{separator} #{reportFilter(aData)} #{separator}"
		end
	end
end


class CsvReporter < Reporter
	def self.titleOut(title)
		puts ""
	end

	def self._conv(aData, keyOutput=false, valOutput=true, firstLine=false)
		aLine = ""
		if aData.kind_of?(Enumerable) then
			if aData.kind_of?(Hash) then
				aData.each do |aKey,theVal|
					aLine = "#{aLine!="" ? "#{aLine}," : ""}#{aKey}" if keyOutput
					aLine = "#{aLine!="" ? "#{aLine}," : ""}#{theVal}" if valOutput
				end
			elsif aData.kind_of?(Array) then
				aData.each do |theVal|
					aLine = "#{aLine!="" ? "#{aLine}," : ""}#{theVal}" if valOutput
				end
			end
			puts aLine
		else
			puts "#{aData}"
		end
	end
end


parser = XmlPerLibReporterParser
resultCollector = ResultCollectorHash.new()
reporter = MarkdownReporter

#---- main --------------------------
options = {
	:verbose => false,
	:reportFormat => "markdown",
	:outFolder => nil,
	:reportOutPath => ".",
	:version => nil,
	:execTimeOut => 60*3,
	:numOfThreads => TaskManagerAsync.getNumberOfProcessor()
}

opt_parser = OptionParser.new do |opts|
	opts.banner = "Usage: usage report1 report2"

	opts.on("-r", "--reportFormat=", "Specify report format markdown|csv (default:#{options[:reportFormat]})") do |reportFormat|
		case reportFormat.to_s.downcase
		when "markdown"
			reporter = MarkdownReporter
		when "csv"
			reporter = CsvReporter
		end
	end

	opts.on("-o", "--reportOutPath=", "Specify report output path(default:#{options[:reportOutPath]})") do |reportOutPath|
		options[:reportOutPath] = reportOutPath
		FileUtil.ensureDirectory( reportOutPath )
	end

	opts.on("-t", "--execTimeOut=", "Specify exection time out [sec] (default:#{options[:execTimeOut]})") do |execTimeOut|
		execTimeOut = execTimeOut.to_i
		options[:execTimeOut] = execTimeOut if execTimeOut
	end

	opts.on("-j", "--numOfThreads=", "Specify number of threads to analyze (default:#{options[:numOfThreads]})") do |numOfThreads|
		numOfThreads = numOfThreads.to_i
		options[:numOfThreads] = numOfThreads if numOfThreads
	end

	opts.on("", "--verbose", "Enable verbose status output") do
		options[:verbose] = true
	end
end.parse!

reportPaths = []
reportFiles = []

if ARGV.length < 2 then
	puts opt_parser
	exit(-1)
else
	# enumerate lib xml report file paths
	reportPaths << ARGV[0]
	reportPaths << ARGV[1]
	# check path
	reportPaths.each do |aReportPath|
		isFile = FileTest.file?(aReportPath)
		isDirectory = FileTest.directory?(aReportPath)
		if !isFile && !isDirectory  then
			puts aReportPath + " is not found"
			exit(-1)
		end
		if isFile then
			reportFiles << [ aReportPath ]
		elsif isDirectory then
			reportFiles << parser.getListOfReportFiles( aReportPath )
		end
	end
end

# Parse the lib xml report
reports = []
reportFilePathsPerLibName={}
reportFiles.each do |theReportFiles|
	theReports = {}
	theReportFiles.each do |aReportFile|
		result, libName = parser.getResult( aReportFile )
		theReports[libName] = result
		reportFilePathsPerLibName[libName] = [] if !reportFilePathsPerLibName.has_key?(libName)
		reportFilePathsPerLibName[libName] << aReportFile
	end
	reports << theReports
end

# Calc common keys and common lib xml reports in ARGV[0] reports and ARGV[1] reports
commonLibs = []
commonKeys = []

if reports.length == 2 then
	keys = []
	keys << reports[0].keys
	keys << reports[1].keys
	commonKeys = keys[0] & keys[1]
	reports.each do |theReport|
		theCommonReport = {}
		commonKeys.each do |key|
			theCommonReport[key] = theReport[key]
		end
		commonLibs << theCommonReport
	end
end

# Execute compliance checker for the common libs
taskMan = TaskManagerAsync.new( options[:numOfThreads].to_i )
commonKeys.each do |aLib|
	theReportPaths = reportFilePathsPerLibName[aLib]
	if theReportPaths.length == 2 then
		oldVer = ""
		newVer = ""
		if commonLibs.length == 2 then
			oldLib = commonLibs[0][aLib]
			oldVer = oldLib["version"] if oldLib.has_key?("version")
			newLib = commonLibs[1][aLib]
			newVer = newLib["version"] if newLib.has_key?("version")
		end
		taskMan.addTask( AbiComplianceCheckerExecutor.new(
			resultCollector,
			theReportPaths[0], 
			theReportPaths[1], 
			options[:reportOutPath], 
			oldVer, 
			newVer,
			options[:execTimeOut]
		))
	end
end

taskMan.executeAll()
taskMan.finalize()
result = resultCollector.getResult()
result = result.sort.to_h
theResults = []
result.each do |libName, theResult|
	theResults << theResult
end
reporter.report(theResults)
