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
require_relative "StrUtil"

class AndroidUtil
	DEF_ANDROID_MAKEFILES = [
		"Android.mk",
		"Android.bp",
	]
	def self.getListOfAndroidMakefile(imagePath)
		return FileUtil.getRegExpFilteredFiles(imagePath, "Android\.(mk|bp)$")
	end
end

class AndrroidMakefileParser
	def initialize(makefilePath, envFlatten)
		@makefilePath = makefilePath
		@envFlatten = envFlatten
		@isNativeLib = false
	end

	def isNativeLib
		return @isNativeLib
	end

	def dump
		return ""
	end
end


class AndroidMkParser < AndrroidMakefileParser
	def getKeyValueFromLine(aLine)
		key = nil
		value = nil
		pos = aLine.index("=")
		if pos then
			value = aLine.slice(pos+1, aLine.length).strip

			key = aLine.slice(0, pos).strip
			key = key.slice(0, key.length-1).strip if key.end_with?(":")
			if key.end_with?("+") then
				key = key.slice(0, key.length-1).strip
				value = @env.has_key?(key) ? "#{@env[key]} \\ #{value}" : value
			end
		end
		return key, value
	end

	DEF_SUBST_INNER="subst "
	DEF_SUBST="$(#{DEF_SUBST_INNER}"
	def _subst(value)
		pos = value.index(DEF_SUBST)
		if pos then
			substWords = StrUtil.getBlacket( value, "(", ")", pos)
			posEnd = value.index(substWords) + substWords.length + 2
			if substWords.index(DEF_SUBST) then
				substWords = _subst( substWords )
			end
			pos1 = substWords.index(DEF_SUBST_INNER)
			if pos1 then
				substArgs = substWords.slice(pos1+DEF_SUBST_INNER.length, substWords.length).strip.split(",")
				if substArgs.length == 3 then
					target = substArgs[0].strip
					replaceKey = substArgs[1].strip
					replaceVal = substArgs[1].strip
					value = value.slice(0, pos).to_s + target.gsub( replaceKey, replaceVal ).to_s + value.slice(posEnd, value.length).to_s
				end
			end
		end

		return value
	end

	def _envEnsure
		@env.clone.each do |key, val|
			@env[key] = envEnsure(val)
		end
	end

	def envEnsure(value)
		@env.each do |key, replaceValue|
			replaceKey = "\$\(#{key}\)"
			value = value.to_s.gsub(replaceKey, replaceValue.to_s )
		end

		value = _subst(value)

		return value
	end

	DEF_OUTPUT_IDENTIFIER="LOCAL_MODULE" #Regexp.compile("LOCAL_MODULE *:=")
	DEF_INCLUDE_IDENTIFIER="LOCAL_C_INCLUDES" #Regexp.compile("LOCAL_C_INCLUDES *(\\+|:)=")

	def parseMakefile(makefileBody)
		theLine = ""
		makefileBody.each do |aLine|
			aLine.strip!
			theLine = "#{theLine} #{aLine}"
			if !aLine.end_with?("\\") then
				key, value = getKeyValueFromLine( theLine )
				if key and value then
					value = envEnsure(value) if @envFlatten
					@env[key] = value 
				end

				if value then
					case key
					when DEF_INCLUDE_IDENTIFIER
						val = value.to_s.split("\\").map(&:strip!)
						val.each do |aVal|
							@nativeIncludes << aVal if aVal
						end
						@nativeIncludes.uniq!
					when DEF_OUTPUT_IDENTIFIER
						@builtOuts << value if value
					else
					end
				end

				theLine = ""
			end
		end
		_envEnsure()
	end

	DEF_NATIVE_LIB_IDENTIFIER=[
		Regexp.compile("\(BUILD_(STATIC|SHARED)_LIBRARY\)"),
		Regexp.compile("LOCAL_MODULE_CLASS.*\=.*(STATIC|SHARED)_LIBRARIES")
	]

	def initialize(makefilePath, envFlatten)
		super(makefilePath, envFlatten)

		@env = {}
		@env["call my-dir"] = FileUtil.getDirectoryFromPath(@makefilePath)
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
	:envFlatten => false,
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

	opts.on("-e", "--envFlatten", "Enable env value flatten") do
		options[:envFlatten] = true
	end

	opts.on("-v", "--verbose", "Enable verbose status output") do
		options[:verbose] = true
	end
end.parse!

makefilePaths = []

if ARGV.length < 1 then
	puts opt_parser
	exit(-1)
else
	# check path
	isFile = FileTest.file?(ARGV[0])
	isDirectory = FileTest.directory?(ARGV[0])
	if !isFile && !isDirectory  then
		puts ARGV[0] + " is not found"
		exit(-1)
	end
	if isFile then
		makefilePaths = [ ARGV[0] ]
	elsif isDirectory then
		makefilePaths = AndroidUtil.getListOfAndroidMakefile( ARGV[0] )
	end
end

puts makefilePaths if options[:verbose]

result = []
makefilePaths.each do | aMakefilePath |
	aParser = AndroidMkParser.new( aMakefilePath, options[:envFlatten] )
	result << aParser if aParser.isNativeLib()
end

result.each do |aNativeLib|
	puts aNativeLib.dump()
end