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

	def initialize(libXmlPath1, libXmlPath2, reportOutPath, oldVer="", newVer="")
		@libXmlPath1 = File.expand_path(libXmlPath1)
		@libXmlPath2 = File.expand_path(libXmlPath2)
		@reportOutPath = reportOutPath
		@libName = XmlPerLibReporterParser.getFilenameFromPathWithoutExt(libXmlPath1)
		@oldVer = oldVer.to_s
		@newVer = newVer.to_s
	end

	def execute
		reportPath = ""
		exec_cmd = "#{DEF_ACC} -lib #{Shellwords.escape(@libName)} -old #{Shellwords.escape(@libXmlPath1)} -new #{Shellwords.escape(@libXmlPath2)}"
		exec_cmd = exec_cmd + " -v1 #{@oldVer}" if !@oldVer.empty?
		exec_cmd = exec_cmd + " -v2 #{@newVer}" if !@newVer.empty?
		exec_cmd = exec_cmd + " --gcc-path=#{Shellwords.escape(DEF_GCC_PATH)}" if DEF_GCC_PATH

		puts exec_cmd

		result = ExecUtil.getExecResultEachLine(exec_cmd, @reportOutPath, false, true, true)

		#TODO: Parse the result

		reportPath = "#{@reportOutPath}/compat_reports/#{@libName}"
		
		return reportPath
	end
end


parser = XmlPerLibReporterParser


#---- main --------------------------
options = {
	:verbose => false,
	:reportFormat => "xml-perlib",
	:outFolder => nil,
	:reportOutPath => ".",
	:version => nil,
}

opt_parser = OptionParser.new do |opts|
	opts.banner = "Usage: usage report1 report2"

	opts.on("-r", "--reportFormat=", "Specify report format markdown|csv|xml|xml-perlib (default:#{options[:reportFormat]})") do |reportFormat|
		case reportFormat.to_s.downcase
		when "markdown"
		when "csv"
		when "xml"
		when "xml-perlib"
			parser = XmlPerLibReporterParser
		end
	end

	opts.on("-o", "--reportOutPath=", "Specify report outpit path(default:#{options[:reportOutPath]})") do |reportOutPath|
		options[:reportOutPath] = reportOutPath
		FileUtil.ensureDirectory( reportOutPath )
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

# Execute the common libs
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
		acc = AbiComplianceChecker.new( theReportPaths[0], theReportPaths[1], options[:reportOutPath], oldVer, newVer )
		acc.execute()
	end
end
