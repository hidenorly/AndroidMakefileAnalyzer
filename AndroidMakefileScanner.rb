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
require_relative 'FileUtil'
require_relative 'StrUtil'

class AndroidUtil
	DEF_ANDROID_MAKEFILES = [
		"Android.mk",
		"Android.bp",
	]
	def self.getListOfAndroidMakefile(imagePath)
		return FileUtil.getRegExpFilteredFiles(imagePath, "Android\.(mk|bp)$")
	end

	def self.getListOfNativeLibsInBuiltOut(builtOutPath)
		return FileUtil.getRegExpFilteredFiles(builtOutPath, "\.(so|a)$")
	end

	def self.getFilenameFromPathWithoutSoExt( path )
		path = FileUtil.getFilenameFromPath(path)
		pos = path.to_s.rindex(".so")
		path = pos ? path.slice(0, pos) : path
		return path
	end

	def self.replaceLibPathWithBuiltOuts( original, nativeLibsInBuiltOut, enableOnlyFoundLibs = false )
		result = []
		builtOutCache = {}

		nativeLibsInBuiltOut.each do |aLibPath|
			builtOutCache[ getFilenameFromPathWithoutSoExt( aLibPath ) ] = aLibPathaLibPath if !enableOnlyFoundLibs || enableOnlyFoundLibs && File.exist?(aLibPath) && File.size?(aLibPath)>0
		end

		original.each do |aResult|
			foundLib = false
			if aResult.has_key?("libs") then
				libs = aResult["libs"]
				replacedLibs = []
				libs.to_a.each do |aLib|
					key = getFilenameFromPathWithoutSoExt(aLib)
					if builtOutCache.has_key?( key ) then
						foundLib = true
						replacedLibs << builtOutCache[key]
					else
						replacedLibs << aLib if !enableOnlyFoundLibs
					end
				end
				aResult["libs"] = replacedLibs
			end

			aResult["libName"] = AndroidUtil.getFilenameFromPathWithoutSoExt(aResult["libs"].to_a[0]) if !aResult["libs"].to_a.empty?

			result << aResult if !enableOnlyFoundLibs || foundLib
		end

		return result
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
				break
			end
		end
		parseMakefile(makefileBody) if @isNativeLib
	end

	def getResult(defaultVersion)
		result = {}
		result["libName"] = AndroidUtil.getFilenameFromPathWithoutSoExt(@builtOuts.to_a[0])
		result["version"] = defaultVersion.to_s #TODO: get version and use it if it's not specified
		result["headers"] = @nativeIncludes
		result["libs"] = @builtOuts
		return result
	end

	def dump
		return "path:#{@makefilePath}, nativeLib:#{@isNativeLib ? "true" : "false"}, builtOuts:#{@builtOuts.to_s}, includes:#{@nativeIncludes.to_s}"
	end
end



class AndroidBpParser < AndroidMakefileParser
	DEF_NATIVE_LIB_IDENTIFIER=[
		"cc_library",
		"cc_library_shared",
		"cc_library_static"
	]

	DEF_LIB_NAME = "name"
	DEF_INCLUDE_DIRS = [
		"export_include_dirs",
		"header_libs",
		"export_header_lib_headers"
	]

	def ensureJson(body)
		return "{ #{body} }".gsub(/(\w+)\s*:/, '"\1":').gsub(/,(?= *\])/, '').gsub(/,(?= *\})/, '')
	end

	def removeRemark(makefileBody)
		result = []
		makefileBody.each do | aLine |
			pos = aLine.index("//")
			if pos then
				aLine = aLine.slice(0,pos)
			end
			result << aLine if !aLine.empty?
		end
		return result
	end

	def parseMakefile(makefileBody)
		body = removeRemark(makefileBody).join(" ")
		baseDir = FileUtil.getDirectoryFromPath(@makefilePath)
		DEF_NATIVE_LIB_IDENTIFIER.each do |aCondition|
			pos = body.index(aCondition)
			if pos then
				theBody = StrUtil.getBlacket(body, "{", "}", pos)
				ensuredJson = ensureJson(theBody)

				theLib = {}
				begin
					theLib = JSON.parse(ensuredJson)
				rescue => ex

				end
				if !theLib.empty? then
					@isNativeLib = true
					@builtOuts << theLib[DEF_LIB_NAME] if theLib.has_key?(DEF_LIB_NAME)
					DEF_INCLUDE_DIRS.each do |anIncludeIdentifier|
						if theLib.has_key?(anIncludeIdentifier) then
							theLib[anIncludeIdentifier].to_a.each do |anInclude|
								@nativeIncludes << "#{baseDir}/#{anInclude}"
							end
						end
					end
				end
			end
		end
		@nativeIncludes.uniq!
		@builtOuts.uniq!
	end

	def initialize(makefilePath, envFlatten)
		super(makefilePath, envFlatten)

		@nativeIncludes = []
		@builtOuts = []
		@isNativeLib = false
		makefileBody = FileUtil.readFileAsArray(makefilePath)
		parseMakefile(makefileBody)
	end

	def getResult(defaultVersion)
		result = {}
		result["libName"] = AndroidUtil.getFilenameFromPathWithoutSoExt(@builtOuts.to_a[0])
		result["version"] = defaultVersion.to_s #TODO: use defaultVersion if not found
		result["headers"] = @nativeIncludes
		result["libs"] = @builtOuts
		return result
	end

	def dump
		return "path:#{@makefilePath}, nativeLib:#{@isNativeLib ? "true" : "false"}, builtOuts:#{@builtOuts.to_s}, includes:#{@nativeIncludes.to_s}"
	end
end


class Reporter
	def setupOutStream(reportOutPath)
		outStream = reportOutPath ? FileUtil.getFileWriter(reportOutPath) : nil
		outStream = outStream ? outStream : STDOUT
		@outStream = outStream
	end

	def initialize(reportOutPath)
		setupOutStream(reportOutPath)
	end

	def close()
		if @outStream then
			@outStream.close() if @outStream!=STDOUT
			@outStream = nil
		end
	end

	def titleOut(title)
		@outStream.puts title if @outStream
	end

	def _getMaxLengthData(data)
		result = !data.empty? ? data[0] : {}

		data.each do |aData|
			result = aData if aData.kind_of?(Enumerable) && aData.to_a.length > result.to_a.length
		end

		return result
	end

	def _ensureFilteredHash(data, outputSections)
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

	def report(data, outputSections=nil, options={})
		outputSections = outputSections ? outputSections.split("|") : nil

		if data.length then
			keys = _getMaxLengthData(data) #data[0]
			if keys.kind_of?(Hash) then
				keys = _ensureFilteredHash(keys, outputSections)
				_conv(keys, true, false, true, options)
			elsif outputSections then
				_conv(outputSections, true, false, true, options)
			end

			data.each do |aData|
				aData = _ensureFilteredHash(aData, outputSections) if aData.kind_of?(Hash)
				_conv(aData)
			end
		end
	end

	def _conv(aData, keyOutput=false, valOutput=true, firstLine=false, options={})
		@outStream.puts aData if @outStream
	end
end

class MarkdownReporter < Reporter
	def initialize(reportOutPath)
		super(reportOutPath)
	end
	def titleOut(title)
		if @outStream
			@outStream.puts "\# #{title}"
			@outStream.puts ""
		end
	end

	def reportFilter(aLine)
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

	def _conv(aData, keyOutput=false, valOutput=true, firstLine=false, options={})
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
			@outStream.puts aLine if @outStream
			if firstLine && count then
				aLine = "|"
				for i in 1..count do
					aLine = "#{aLine} :--- |"
				end
				@outStream.puts aLine if @outStream
			end
		else
			@outStream.puts "#{separator} #{reportFilter(aData)} #{separator}" if @outStream
		end
	end
end

class CsvReporter < Reporter
	def initialize(reportOutPath)
		super(reportOutPath)
	end

	def titleOut(title)
		@outStream.puts "" if @outStream
	end

	def reportFilter(aLine)
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

	def _conv(aData, keyOutput=false, valOutput=true, firstLine=false, options={})
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
			@outStream.puts aLine if @outStream
		else
			@outStream.puts "#{reportFilter(aData)}" if @outStream
		end
	end
end

class XmlReporter < Reporter
	def initialize(reportOutPath)
		super(reportOutPath)
	end

	def titleOut(title)
		if @outStream then
			@outStream.puts "<!-- #{title} --/>"
			@outStream.puts ""
		end
	end

	def reportFilter(aLine)
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

	def report(data, outputSections=nil, options={})
		outputSections = outputSections ? outputSections.split("|") : nil
		mainKey = nil
		if outputSections then
			mainKey = outputSections[0]
		end

		data.each do |aData|
			aData = _ensureFilteredHash(aData, outputSections) if aData.kind_of?(Hash)
			if mainKey then
				mainVal = aData.has_key?(mainKey) ? aData[mainKey] : ""
				aData.delete(mainKey)
				@outStream.puts "<#{mainKey} #{mainVal ? "value=\"#{mainVal}\"" : ""}>" if @outStream
				_subReport(aData, 4)
				@outStream.puts "</#{mainKey}>" if @outStream
			else
				_subReport(aData, 0)
			end
		end
	end

	def _isEnumerable(theData)
		result = false
		theData.each do |aData|
			if aData.kind_of?(Enumerable) then
				result = true
				break
			end
		end
		return result
	end

	def _subReport(aData, baseIndent=4, keyOutput=true, valOutput=true, firstLine=false)
		separator = "\n"
		if aData.kind_of?(Enumerable) then
			indent = baseIndent + 4
			if aData.kind_of?(Hash) then
				aData.each do |aKey,theVal|
					@outStream.puts "#{" "*baseIndent}<#{aKey}>" if @outStream
					if theVal.kind_of?(Enumerable) then
						_subReport(theVal, indent)
					else
						aVal = reportFilter(theVal)
						if aVal && !aVal.empty? then
							@outStream.puts "#{" "*indent}#{aVal}" if @outStream
						end
					end
					@outStream.puts "#{" "*baseIndent}</#{aKey}>" if @outStream
				end
			elsif aData.kind_of?(Array) then
				isEnumerable = _isEnumerable(aData)
				@outStream.puts "#{" "*baseIndent}<data>" if isEnumerable && @outStream
				aLine = ""
				aData.each do |theVal|
					if theVal.kind_of?(Enumerable) then
						_subReport(theVal, indent)
					else
						aVal = reportFilter(theVal)
						if aVal && !aVal.empty? then
							aLine = "#{aLine}#{" "*indent}#{aVal}#{separator}" if valOutput
						end
					end
				end
				if @outStream then
					@outStream.puts aLine
					@outStream.puts "#{" "*baseIndent}</data>" if isEnumerable
				end
			else
				aVal = reportFilter(aData)
				if aVal && !aVal.empty? then
					@outStream.puts "#{" "*indent}#{aVal}" if @outStream
				end
			end
		else
			aVal = reportFilter(aData)
			if aVal && !aVal.empty? then
				@outStream.puts "#{" "*indent}#{aVal}" if @outStream
			end
		end
	end
end

class XmlReporterPerLib < XmlReporter
	def initialize(reportOutPath)
		@reportOutPath = reportOutPath
		@outStream = nil
	end

	def report(data, outputSections=nil, options={})
		outputSections = outputSections ? outputSections.split("|") : nil
		mainKey = nil
		if outputSections then
			mainKey = outputSections[0]
		end

		data.each do |aData|
			aData = _ensureFilteredHash(aData, outputSections) if aData.kind_of?(Hash)
			reportPath = @reportOutPath
			if mainKey then
				mainVal = aData.has_key?(mainKey) ? aData[mainKey] : "library"
				aData.delete(mainKey)
				baseDir = @reportOutPath.to_s.include?(".xml") ? FileUtil.getDirectoryFromPath(@reportOutPath) : @reportOutPath
				reportPath = "#{baseDir}/#{mainVal}.xml"
			end
			FileUtil.ensureDirectory( FileUtil.getDirectoryFromPath(reportPath) )
			setupOutStream( reportPath )
			_subReport(aData, 0)
			@outStream.close() if @outStream!=STDOUT
		end
	end
end


#---- main --------------------------
options = {
	:verbose => false,
	:envFlatten => false,
	:reportFormat => "xml",
	:outFolder => nil,
	:filterOutMatch => false,
	:reportOutPath => nil,
	:version => nil,
}

reporter = XmlReporter

opt_parser = OptionParser.new do |opts|
	opts.banner = "Usage: usage ANDROID_HOME"

	opts.on("-r", "--reportFormat=", "Specify report format markdown|csv|xml|xml-perlib (default:#{options[:reportFormat]})") do |reportFormat|
		case reportFormat.to_s.downcase
		when "markdown"
			reporter = MarkdownReporter
		when "csv"
			reporter = CsvReporter
		when "xml"
			reporter = XmlReporter
		when "xml-perlib"
			reporter = XmlReporterPerLib
		end
	end

	opts.on("-e", "--envFlatten", "Enable env value flatten") do
		options[:envFlatten] = true
	end

	opts.on("-v", "--version=", "Set default version in the lib report") do |version|
		options[:version] = version.to_s
	end

	opts.on("-p", "--reportOutPath=", "Specify report output folder if you want to report out as file") do |reportOutPath|
		options[:reportOutPath] = reportOutPath
	end

	opts.on("-o", "--outMatch=", "Specify built out folder if you want to use built out file match") do |outFolder|
		options[:outFolder] = outFolder
	end

	opts.on("-f", "--filterOutMatch", "Specify if you want to output libs found in --outMatch") do
		options[:filterOutMatch] = true
	end

	opts.on("", "--verbose", "Enable verbose status output") do
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

nativeLibsInBuiltOut = []
if options[:outFolder] then
	nativeLibsInBuiltOut = AndroidUtil.getListOfNativeLibsInBuiltOut(options[:outFolder])
end

puts makefilePaths if options[:verbose]

result = []
makefilePaths.each do | aMakefilePath |
	aParser = aMakefilePath.end_with?(".mk") ? AndroidMkParser.new( aMakefilePath, options[:envFlatten] ) : AndroidBpParser.new( aMakefilePath, options[:envFlatten] )
	result << aParser.getResult(options[:version]) if aParser.isNativeLib()
end

if !nativeLibsInBuiltOut.empty? then
	result = AndroidUtil.replaceLibPathWithBuiltOuts( result, nativeLibsInBuiltOut, options[:filterOutMatch] )
end

reporter = reporter.new( options[:reportOutPath] )
reporter.report( result, "libName|version|headers|libs", options )
reporter.close()
