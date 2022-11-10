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


class CppCheckExecutor < TaskAsync
	def initialize(resultCollector, path)
		super("CppCheckExecutor #{path}")
		@resultCollector = resultCollector
		@path = path.to_s
	end

	def execute
		results = []
		@resultCollector.onResult(@path, results) if @resultCollector && results && !results.empty?
		_doneTask()
	end
end



#---- main --------------------------
options = {
	:verbose => false,
	:reportOutPath => nil,
	:numOfThreads => TaskManagerAsync.getNumberOfProcessor()
}

reporter = MarkdownReporter
resultCollector = ResultCollectorHash.new()

opt_parser = OptionParser.new do |opts|
	opts.banner = "Usage: usage ANDROID_HOME"

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

	opts.on("-p", "--reportOutPath=", "Specify report output folder if you want to report out as file") do |reportOutPath|
		options[:reportOutPath] = reportOutPath
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
	end
end


taskMan = ThreadPool.new( options[:numOfThreads].to_i )
componentPaths.each do | aPath |
	taskMan.addTask( CppCheckExecutor.new( resultCollector, aPath ) )
end
taskMan.executeAll()
taskMan.finalize()

_result = resultCollector.getResult()
_result = _result.sort

_reporter = reporter.new( options[:reportOutPath] )
_reporter.report( _result, nil, options )
_reporter.close()
