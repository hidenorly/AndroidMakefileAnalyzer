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

class AndroidMakefileParser
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


class AndroidMkParser < AndroidMakefileParser
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

	def getResult
		result = {}
		result["libName"] = FileUtil.getFilenameFromPathWithoutExt(@builtOuts.to_a[0])
		result["version"] = ""
		result["headers"] = @nativeIncludes
		result["libs"] = @builtOuts
		return result
	end

	def dump
		return "path:#{@makefilePath}, nativeLib:#{@isNativeLib ? "true" : "false"}, builtOuts:#{@builtOuts.to_s}, includes:#{@nativeIncludes.to_s}"
	end
end


class Reporter
	def self.titleOut(title)
		puts title
	end

	def self._getMaxLengthData(data)
		result = !data.empty? ? data[0] : {}

		data.each do |aData|
			result = aData if aData.kind_of?(Enumerable) && aData.to_a.length > result.to_a.length
		end

		return result
	end

	def self._ensureFilteredHash(data, outputSections)
		result = data

		if outputSections then
			result = {}

			outputSections.each do |aKey|
				found = false
				data.each do |theKey, theVal|
					if theKey.to_s.strip.start_with?(aKey) then
						result[aKey] = theVal
						found = true
						break
					end
				end
				result[aKey] = nil if !found
			end
		end

		return result
	end

	def self.report(data, outputSections=nil)
		outputSections = outputSections ? outputSections.split("|") : nil

		if data.length then
			keys = _getMaxLengthData(data) #data[0]
			if keys.kind_of?(Hash) then
				keys = _ensureFilteredHash(keys, outputSections)
				_conv(keys, true, false, true)
			elsif outputSections then
				_conv(outputSections, true, false, true)
			end

			data.each do |aData|
				aData = _ensureFilteredHash(aData, outputSections) if aData.kind_of?(Hash)
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
		if aLine.kind_of?(Array) then
			tmp = ""
			aLine.each do |aVal|
				tmp = "#{tmp}#{!tmp.empty? ? " <br> " : ""}#{aVal}"
			end
			aLine = tmp
		elsif aLine.is_a?(String) then
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

	def self.reportFilter(aLine)
		if aLine.kind_of?(Array) then
			tmp = ""
			aLine.each do |aVal|
				tmp = "#{tmp}#{!tmp.empty? ? "|" : ""}#{aVal}"
			end
			aLine = tmp
		elsif aLine.is_a?(String) then
			aLine = "[#{FileUtil.getFilenameFromPath(aLine)}](#{aLine})" if aLine.start_with?("http://")
		end

		return aLine
	end

	def self._conv(aData, keyOutput=false, valOutput=true, firstLine=false)
		aLine = ""
		if aData.kind_of?(Enumerable) then
			if aData.kind_of?(Hash) then
				aData.each do |aKey,theVal|
					aLine = "#{aLine!="" ? "#{aLine}," : ""}#{aKey}" if keyOutput
					aLine = "#{aLine!="" ? "#{aLine}," : ""}#{reportFilter(theVal)}" if valOutput
				end
			elsif aData.kind_of?(Array) then
				aData.each do |theVal|
					aLine = "#{aLine!="" ? "#{aLine}," : ""}#{reportFilter(theVal)}" if valOutput
				end
			end
			puts aLine
		else
			puts "#{reportFilter(aData)}"
		end
	end
end

class XmlReporter < Reporter
	def self.titleOut(title)
		puts "<!-- #{title} --/>"
		puts ""
	end

	def self.reportFilter(aLine)
		if aLine.kind_of?(Array) then
			tmp = ""
			aLine.each do |aVal|
				tmp = "#{tmp}#{!tmp.empty? ? "\n" : ""}#{aVal}"
			end
			aLine = tmp
		elsif aLine.is_a?(String) then
			aLine = "[#{FileUtil.getFilenameFromPath(aLine)}](#{aLine})" if aLine.start_with?("http://")
		end

		return aLine
	end

	def self.report(data, outputSections=nil)
		outputSections = outputSections ? outputSections.split("|") : nil

		data.each do |aData|
			aData = _ensureFilteredHash(aData, outputSections) if aData.kind_of?(Hash)
			libName = aData.has_key?("libName") ? aData["libName"] : ""
			aData.delete("libName")
			puts "<library name=\"#{libName}\">"
			_subReport(aData, 4)
			puts "</library>"
		end
	end

	def self._subReport(aData, baseIndent=4, keyOutput=true, valOutput=true, firstLine=false)
		separator = "\n"
		aData.each do |aKey,theVal|
			aLine = ""
			puts "#{" "*baseIndent}<#{aKey}>"
			indent = baseIndent + 4
			# TODO: do as recursive
			if theVal.kind_of?(Enumerable) then
				if theVal.kind_of?(Hash) then
					theVal.each do |aSubKey,theSubVal|
						aVal = reportFilter(theSubVal)
						if aVal && !aVal.empty? then
							aLine = "#{" "*indent}<#{aSubKey}>#{separator}" if keyOutput
							aLine = "#{aLine}#{" "*(indent+4)}#{aVal}#{separator}" if valOutput
							aLine = "#{aLine}#{" "*indent}</#{aSubKey}>#{separator}" if keyOutput
						end
					end
				elsif theVal.kind_of?(Array) then
					theVal.each do |theVal|
						aVal = reportFilter(theVal)
						if aVal && !aVal.empty? then
							aLine = "#{aLine}#{" "*indent}#{aVal}#{separator}" if valOutput
						end
					end
				end
				puts aLine
			else
				aVal = reportFilter(theVal)
				if aVal && !aVal.empty? then
					puts "#{" "*indent}#{aVal}"
				end
			end
			puts "#{" "*baseIndent}</#{aKey}>"
		end
	end
end


#---- main --------------------------
options = {
	:verbose => false,
	:envFlatten => false,
	:reportFormat => "xml",
}

reporter = XmlReporter

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
	result << aParser.getResult() if aParser.isNativeLib()
end

reporter.report( result, "libName|version|headers|libs" )
