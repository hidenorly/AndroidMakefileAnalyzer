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
require_relative "FileUtil"

class AndroidUtil
	DEF_ANDROID_MAKEFILES = [
		"Android.mk",
		"Android.bp",
	]
	def self.getListOfAndroidMakefile(imagePath)
		return FileUtil.getRegExpFilteredFiles(imagePath, "Android\.(mk|bp)$")
	end
end

class AndroidMkParser
	DEF_OUTPUT_IDENTIFIER=Regexp.compile("LOCAL_MODULE *:=")
	DEF_INCLUDE_IDENTIFIER=Regexp.compile("LOCAL_C_INCLUDES *(\\+|:)=")

	def getValueFromLine(aLine, identifier)
		result = nil
		if aLine.match(identifier) then
			pos = aLine.index("=")
			if pos then
				result = aLine.slice(pos+1, aLine.length).strip
			end
		end
		return result
	end

	def parseMakefile(makefileBody)
		theLine = ""
		makefileBody.each do |aLine|
			aLine.strip!
			theLine = "#{theLine} #{aLine}"
			if !aLine.end_with?("\\") then
				val = getValueFromLine( theLine, DEF_INCLUDE_IDENTIFIER )
				val = val.to_s.split("\\").map(&:strip!)
				@nativeIncludes.concat( val ) if !val.empty?

				val = getValueFromLine( theLine, DEF_OUTPUT_IDENTIFIER )
				@builtOuts << val if val

				theLine = ""
			end
		end
	end

	def isNativeLib
		return @isNativeLib
	end

	DEF_NATIVE_LIB_IDENTIFIER=[
		Regexp.compile("\(BUILD_(STATIC|SHARED)_LIBRARY\)"),
		Regexp.compile("LOCAL_MODULE_CLASS.*\=.*(STATIC|SHARED)_LIBRARIES")
	]

	def initialize(makefilePath)
		@makefilePath = makefilePath
		@isNativeLib = false
		@nativeIncludes = []
		@builtOuts = []
		makefileBody = FileUtil.readFileAsArray(makefilePath)
		DEF_NATIVE_LIB_IDENTIFIER.each do | aCondition |
			result = makefileBody.grep(aCondition)
			if !result.empty? then
				# found native lib
				@isNativeLib = true
				#break
			end
		end
		parseMakefile(makefileBody) if @isNativeLib
	end

	def dump
		return "path:#{@makefilePath}, nativeLib:#{@isNativeLib ? "true" : "false"}, builtOuts:#{@builtOuts.to_s}, includes:#{@nativeIncludes.to_s}"
	end
end


#---- main --------------------------
options = {
	:verbose => false,
}

opt_parser = OptionParser.new do |opts|
	opts.banner = "Usage: usage ANDROID_HOME"

	opts.on("-r", "--reportFormat=", "Specify report format markdown|csv|ruby (default:markdown)") do |reportFormat|
		case reportFormat.to_s.downcase
		when "ruby"
			reporter = Reporter
		when "csv"
			reporter = CsvReporter
		end
	end

	opts.on("-v", "--verbose", "Enable verbose status output") do
		options[:verbose] = true
	end
end.parse!

if (ARGV.length < 1) then
	puts opt_parser
	exit(-1)
else
	# check path
	if ( !FileTest.directory?(ARGV[0]) ) then
		puts ARGV[0] + " is not found"
		exit(-1)
	end
end

makefilePaths = AndroidUtil.getListOfAndroidMakefile( ARGV[0] )
puts makefilePaths if options[:verbose]

result = []
makefilePaths.each do | aMakefilePath |
	aParser = AndroidMkParser.new( aMakefilePath )
	result << aParser if aParser.isNativeLib()
end

result.each do |aNativeLib|
	puts aNativeLib.dump()
end