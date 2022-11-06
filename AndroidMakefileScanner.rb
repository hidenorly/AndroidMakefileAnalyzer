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
require_relative 'TaskManager.rb'

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
	DEF_ANDROID_MAKEFILES = [
		"Android.mk",
		"Android.bp",
	]
	def self.getListOfAndroidMakefile(imagePath)
		gitPaths = RepoUtil.getPathesFromManifest(imagePath)
		gitPaths = [imagePath] if gitPaths.empty?

		result = FileUtil.getRegExpFilteredFilesMT(gitPaths, "Android\.(bp|mk)")

		return result
	end


	DEF_INTERMEDIATE_BUILTOUTS=[
		"/obj/PACKAGING/target_files_intermediates/",
		"/obj/SHARED_LIBRARIES/",
		"/symbols/"
	]

	def self.excludesKnownIntermediatesBuiltOuts(builtOuts)
		results = []
		builtOuts.each do | aBuiltOut |
			isExclude = false
			DEF_INTERMEDIATE_BUILTOUTS.each do |anExclusion|
				if aBuiltOut.include?(anExclusion) then
					isExclude = true
					break
				end
			end
			results << aBuiltOut if !isExclude
		end
		return results
	end


	def self.getListOfBuiltOuts(builtOutPath, isNativeLib = true, isApk = true, isJar = true, isApex = true)
		searchTarget = []
		searchTarget << "so|a" if isNativeLib
		searchTarget << "apk" if isApk
		searchTarget << "jar" if isJar
		searchTarget << "apex" if isApex
		searchTarget = searchTarget.join("|")
		searchTarget = searchTarget.slice(0, searchTarget.length-1) if searchTarget.end_with?("|")
		return searchTarget ? excludesKnownIntermediatesBuiltOuts( FileUtil.getRegExpFilteredFilesMT2(builtOutPath, "\.(#{searchTarget})$") ) : []
	end

	DEF_BUILTS_OUT_EXTS=[
		".so",
		".apk",
		".jar",
		".apex"
	]
	def self.getFilenameFromPathWithoutExt( path )
		path = path.to_s
		path = FileUtil.getFilenameFromPath(path)
		DEF_BUILTS_OUT_EXTS.each do |anExt|
			pos = path.to_s.rindex(anExt)
			if pos then
				path = path.slice(0, pos)
				break
			end
		end
		return path
	end

	DEF_ANDROID_ROOT=[
	    "/system/",
	    "/frameworks/",
	    "/device/",
	    "/vendor/",
	    "/packages/",
	    "/external/",
	    "/hardware/",
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

class AndroidMakefileParser
	class ParseResult
		attr_accessor :builtOuts

		attr_accessor :libName
		attr_accessor :nativeIncludes
		attr_accessor :cflags

		attr_accessor :apkName
		attr_accessor :jarName
		attr_accessor :apexName
		attr_accessor :certificate
		attr_accessor :dexPreOpt
		attr_accessor :optimizeEnabled
		attr_accessor :optimizeShrink		

		def initialize
			@builtOuts = []

			@libName = ""
			@nativeIncludes = []
			@cflags = []

			@apkName = ""
			@jarName = ""
			@apexName = ""
			@certificate = ""
			@dexPreOpt = "true"
			@optimizeEnabled = "true"
			@optimizeShrink = "true"
		end
	end

	def initialize(makefilePath, envFlatten, compilerFilter, enableNativeScan = true, enableApkScan = true, enableJarScan = true, enableApexScan = true)
		@makefilePath = makefilePath
		@makefileDirectory = FileUtil.getDirectoryFromPath(makefilePath)
		@androidRootPath = AndroidUtil.getAndroidRootPath(makefilePath)
		@envFlatten = envFlatten

		@isNativeLib = false
		@isApk = false
		@isJar = false
		@isApex = false

		@enableNativeScan = enableNativeScan
		@enableApkScan = enableApkScan
		@enableJarScan = enableJarScan
		@enableApexScan = enableApexScan

		@currentResult = ParseResult.new()
		@results = [@currentResult]

		@compilerFilter = compilerFilter
	end

	def isNativeLib
		return @isNativeLib
	end

	def isApk
		return @isApk
	end

	def isJar		
		return @isJar
	end

	def isApex
		return @isApex
	end

	def getResults(defaultVersion)
		results = []

		@results.each do |aResult|
			result = {}

			aResult.nativeIncludes.uniq!
			aResult.builtOuts.uniq!
			aResult.cflags.uniq!
	
			if @isNativeLib && (!aResult.nativeIncludes.empty? || !aResult.cflags.empty?) then
				result["libName"] = aResult.libName #? aResult.libName : AndroidUtil.getFilenameFromPathWithoutExt(aResult.builtOuts.to_a[0])
				result["version"] = defaultVersion.to_s #TODO: get version and use it if it's not specified
				result["headers"] = aResult.nativeIncludes
				result["builtOuts"] = aResult.builtOuts
				result["gcc_options"] = aResult.cflags
			end
			if @isApk && aResult.apkName then
				result["apkName"] = aResult.apkName
				result["builtOuts"] = aResult.builtOuts
				result["certificate"] = aResult.certificate
				result["dexPreOpt"] = aResult.dexPreOpt
				result["optimizeEnabled"] = aResult.optimizeEnabled
				result["optimizeShrink"] = aResult.optimizeShrink
			end
			if @isJar && aResult.jarName then
				result["jarName"] = aResult.jarName
				result["jarPath"] = aResult.builtOuts
				result["builtOuts"] = aResult.builtOuts
				result["certificate"] = aResult.certificate
				result["dexPreOpt"] = aResult.dexPreOpt
			end
			if @isApex && aResult.apexName then
				result["apexName"] = aResult.apexName
				result["apexPath"] = aResult.builtOuts
				result["builtOuts"] = aResult.builtOuts
				result["certificate"] = aResult.certificate
			end

			results << result if !result.empty?
		end

		return results
	end

	def self.replacePathWithBuiltOuts( original, builtOuts, enableOnlyFoundBuiltOuts = false )
		result = []
		builtOutCache = {}

		builtOuts.each do |aPath|
			builtOutCache[ AndroidUtil.getFilenameFromPathWithoutExt( aPath ) ] = aPath if !enableOnlyFoundBuiltOuts || enableOnlyFoundBuiltOuts && File.exist?(aPath) && File.size(aPath).to_i>0
		end

		original.each do |aResult|
			found = false
			targets = []
			targets = targets | aResult["builtOuts"] if aResult.has_key?("builtOuts")
			targets << aResult["libName"] if aResult.has_key?("libName")
			targets << aResult["apkName"] if aResult.has_key?("apkName")
			targets << aResult["jarName"] if aResult.has_key?("jarName")
			targets << aResult["apexName"] if aResult.has_key?("apexName")

			if !targets.empty? then
				replacedResults = []
				targets.to_a.each do |anTarget|
					key = AndroidUtil.getFilenameFromPathWithoutExt(anTarget)
					if builtOutCache.has_key?( key ) then
						found = true
						replacedResults << builtOutCache[key]
					else
						replacedResults << anTarget if !enableOnlyFoundBuiltOuts
					end
				end
				builtOuts = []
				apkName = ""
				jarName = ""
				apexName = ""
				replacedResults.each do |aReplacedResult|
					aReplacedResult = aReplacedResult.to_s
					builtOuts << aReplacedResult if aReplacedResult.end_with?(".so") || aReplacedResult.end_with?(".a") || aReplacedResult.end_with?(".apk") || aReplacedResult.end_with?(".apex") || aReplacedResult.end_with?(".jar")
					apkName = aReplacedResult if aReplacedResult.end_with?(".apk")
					jarName = aReplacedResult if aReplacedResult.end_with?(".jar")
					apexName = aReplacedResult if aReplacedResult.end_with?(".apex")
				end

				aResult["builtOuts"] = builtOuts if !builtOuts.empty? || enableOnlyFoundBuiltOuts
				aResult["apkName"] = apkName if apkName || enableOnlyFoundBuiltOuts
				aResult["jarName"] = jarName if jarName || enableOnlyFoundBuiltOuts
				aResult["apexName"] = apexName if apexName || enableOnlyFoundBuiltOuts
			end

			aResult["libName"] = AndroidUtil.getFilenameFromPathWithoutExt(aResult["builtOuts"].to_a[0]) if !aResult["builtOuts"].to_a.empty?
			aResult["apkName"] = AndroidUtil.getFilenameFromPathWithoutExt(aResult["apkName"]) if aResult["apkName"]
			aResult["jarName"] = AndroidUtil.getFilenameFromPathWithoutExt(aResult["jarName"]) if aResult["jarName"]
			aResult["apexName"] = AndroidUtil.getFilenameFromPathWithoutExt(aResult["apexName"]) if aResult["apexName"]

			result << aResult if !enableOnlyFoundBuiltOuts || found
		end

		return result
	end

	def dump
		return ""
	end

	def getRobustPath(basePath, thePath)
		result = "#{basePath}/#{thePath}"
		if !File.exist?(result) then
			foundPaths = ""
			thePaths = thePath.split("/")
			thePaths.each do |aPath|
				if basePath.include?(aPath) then
					foundPaths = "#{foundPaths}/#{aPath}"
				else
					break
				end
			end
			foundPaths = foundPaths.slice(1, foundPaths.length) if foundPaths.start_with?("/")
			if !foundPaths.empty? then
				remainingPath = thePath.slice( thePath.index(foundPaths)+foundPaths.length, thePath.length )
				thePath = basePath.slice( 0, thePath.index(foundPaths) ) + remainingPath
			end
			result = "#{basePath}/#{thePath}"
		end

		return result
	end

	DEF_NATIVE_HEADER_EXTENSION="\.(h|hpp)$"
	DEF_NATIVE_SOURCE_EXTENSION="\.c??$"

	def _isNativeHeader(path)
		return true if path.end_with?(".h") || path.end_with?(".hpp") || path.end_with?(".hh") || path.end_with?(".h++")
		return true if path.end_with?(".c") || path.end_with?(".cc") || path.end_with?(".cxx") || path.end_with?(".cpp")
		return false
	end

	def ensureNativeIncludes
		@results.each do |aResult|
			if aResult.nativeIncludes.empty? then
				incPaths = FileUtil.getRegExpFilteredFiles(@makefileDirectory, DEF_NATIVE_HEADER_EXTENSION)
				incPaths = FileUtil.getRegExpFilteredFiles(@makefileDirectory, DEF_NATIVE_SOURCE_EXTENSION) if incPaths.empty?
				incPaths.each do |anInc|
					if _isNativeHeader(anInc) then
						theDir = FileUtil.getDirectoryFromPath(anInc)
						theDir = theDir.slice(0, theDir.length-1) if theDir.end_with?(".")
						theDir = theDir.slice(0, theDir.length-1) if theDir.end_with?("/")
						aResult.nativeIncludes << theDir if !aResult.nativeIncludes.include?(theDir)
					end
				end
			end
			result = []
			aResult.nativeIncludes.each do |anInc|
				anInc = anInc.gsub("//", "/")
				anInc = anInc.slice(0, anInc.length-1) if anInc.end_with?(".")
				anInc = anInc.slice(0, anInc.length-1) if anInc.end_with?("/")
				anInc.strip!
				result << anInc if !anInc.empty?
			end
			aResult.nativeIncludes = result
			aResult.nativeIncludes.uniq!
		end
	end

	def ensureCompilerOption
		@results.each do |aResult|
			aResult.cflags.uniq!
			aResult.cflags = @compilerFilter.filterOption( aResult.cflags )
			aResult.cflags.uniq!
		end
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

	DEF_INC_PATH_MAP={
	    "camera" => "system/media/camera/include",
	    "frameworks-base" => "frameworks/base/include",
	    "frameworks-native" => "frameworks/native/include",
	    "libhardware" => "hardware/libhardware/include",
	    "libhardware_legacy" => "hardware/libhardware_legacy/include",
	    "libril" => "hardware/ril/include",
	    "system-core" => "system/core/include",
	    "audio" => "system/media/audio/include",
	    "audio-effects" => "system/media/audio_effects/include",
	    "audio-utils" => "system/media/audio_utils/include",
	    "audio-route" => "system/media/audio_route/include",
	    "wilhelm" => "frameworks/wilhelm/include",
	    "wilhelm-ut" => "frameworks/wilhelm/src/ut",
	    "mediandk" => "frameworks/av/media/ndk/"
	}

	DEF_INC_PATH_INNER="include-path-for"
	DEF_INC_PATH="$(call #{DEF_INC_PATH_INNER}"
	def _include_path_for(value)
		pos = value.index(DEF_INC_PATH)
		if pos then
			incValue = StrUtil.getBlacket( value, "(", ")", pos)
			posEnd = value.index(incValue) + incValue.length + 1

			pos1 = incValue.index(DEF_INC_PATH_INNER, pos)
			if pos1 then
				incPathArg = incValue.slice(pos1+DEF_INC_PATH_INNER.length+1, incValue.length).strip
				if DEF_INC_PATH_MAP.has_key?(incPathArg) then
					replaceVal = "#{@androidRootPath}/#{DEF_INC_PATH_MAP[incPathArg]}"
					value = value.slice(0, pos).to_s + replaceVal + value.slice(posEnd, value.length).to_s
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
	DEF_CFLAGS_IDENTIFIER = [
		"LOCAL_CPPFLAGS",
		"LOCAL_CFLAGS",
		"LOCAL_CONLYFLAGS"
	]


	DEF_PREBUILT_NAME_IDENTIFIER = "LOCAL_SRC_FILES"
	DEF_PREBUILT_LIBS_IDENTIFIER = "LOCAL_PREBUILT_LIBS"
	DEF_PREBUILT_JAR_IDENTIFIER = "LOCAL_PREBUILT_JAVA_LIBRARIES"
	DEF_PREBUILT_STATIC_JAR_IDENTIFIER = "LOCAL_PREBUILT_STATIC_JAVA_LIBRARIES"


	DEF_APK_PACKAGE_NAME_IDENTIFIER = "LOCAL_PACKAGE_NAME"
	DEF_APK_OPTIMIZE_IDENTIFIER = "LOCAL_PROGUARD_ENABLED"
	DEF_CERTIFICATE_IDENTIFIER = "LOCAL_CERTIFICATE"
	DEF_DEX_PREOPT_IDENTIFIER = "LOCAL_DEX_PREOPT"

	DEF_NATIVE_LIB_IDENTIFIER=[
		Regexp.compile("\(BUILD_(STATIC|SHARED)_LIBRARY\)"),
		Regexp.compile("\(PREBUILT_SHARED_LIBRARY\)")
#		Regexp.compile("LOCAL_MODULE_CLASS.*\=.*(STATIC|SHARED)_LIBRARIES")
	]
	DEF_PREBUILT_IDENTIFIER=[
		Regexp.compile("\(BUILD_PREBUILT\)"),
		Regexp.compile("\(BUILD_MULTI_PREBUILT\)")
	]
	DEF_APK_IDENTIFIER=[
		Regexp.compile("\(BUILD_PACKAGE\)"),
		#Regexp.compile("\(BUILD_CTS_PACKAGE\)"),
		Regexp.compile("\(BUILD_RRO_PACKAGE\)"),
		Regexp.compile("\(BUILD_PHONY_PACKAGE\)"),
#		Regexp.compile("LOCAL_MODULE_CLASS.*\=.*APPS")
	]
	DEF_JAR_IDENTIFIER=[
		Regexp.compile("\(BUILD_STATIC_JAVA_LIBRARY\)"),
		Regexp.compile("\(BUILD_JAVA_LIBRARY\)"),
#		Regexp.compile("LOCAL_MODULE_CLASS.*\=.*JAVA_LIBRARIES")
	]

	def parseMakefile(makefileBody)
		theLine = ""
		targetIdentifiers = DEF_PREBUILT_IDENTIFIER
		targetIdentifiers = targetIdentifiers | DEF_NATIVE_LIB_IDENTIFIER if @enableNativeScan
		targetIdentifiers = targetIdentifiers | DEF_APK_IDENTIFIER if @enableApkScan
		targetIdentifiers = targetIdentifiers | DEF_JAR_IDENTIFIER if @enableJarScan

		makefileBody.each do |aLine|
			aLine.strip!
			targetIdentifiers.each do |aCondition|
				if aLine.match(aCondition) then
					@currentResult.builtOuts.each do |aBuiltOut|
						theName = AndroidUtil.getFilenameFromPathWithoutExt(aBuiltOut)
						@currentResult.libName = theName if DEF_NATIVE_LIB_IDENTIFIER.include?(aCondition)
						@currentResult.apkName = theName if DEF_APK_IDENTIFIER.include?(aCondition)
						@currentResult.jarName = theName if DEF_JAR_IDENTIFIER.include?(aCondition)
					end
					@currentResult = ParseResult.new()
					@results << @currentResult
				end
			end
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
						if @enableNativeScan then
							val = value.to_s.split("\\").map(&:strip!)
							val.each do |aVal|
								if aVal then
									aVal = _include_path_for(aVal.to_s)
									theLibIncludePath = getRobustPath(@makefileDirectory, aVal)
									@currentResult.nativeIncludes << theLibIncludePath if File.exist?(theLibIncludePath)
									theLibIncludePath = getRobustPath(@androidRootPath, aVal)
									@currentResult.nativeIncludes << theLibIncludePath if File.exist?(theLibIncludePath)
								end
							end
						end
					when DEF_OUTPUT_IDENTIFIER
						@currentResult.builtOuts << value if value
					when DEF_DEX_PREOPT_IDENTIFIER
						if @enableApkScan || @enableJarScan then
							@currentResult.dexPreOpt = value if value
						end
					when DEF_APK_PACKAGE_NAME_IDENTIFIER
						@currentResult.apkName = value if value && @enableApkScan
						@isApk = true
					when DEF_CERTIFICATE_IDENTIFIER
						if @enableApkScan || @enableJarScan then
							@currentResult.certificate = value if value
						end
					when DEF_PREBUILT_LIBS_IDENTIFIER, DEF_PREBUILT_JAR_IDENTIFIER, DEF_PREBUILT_STATIC_JAR_IDENTIFIER
						values = value.split(" ")
						@currentResult.builtOuts = (@currentResult.builtOuts | values).uniq
					when DEF_PREBUILT_NAME_IDENTIFIER
						values = value.split(" ")
						values.each do | value |
							@currentResult.builtOuts << value if value.include?(".apk") || value.include?(".apex") || value.include?(".so") || value.include?(".jar")
							if @enableApkScan && value.include?(".apk") then
								@currentResult.apkName = value
								@isApk = true
							elsif @enableNativeScan && value.include?(".so") then
								@currentResult.libName = value
								@isNativeLib = true
							elsif @enableJarScan && value.include?(".jar") then
								@currentResult.jarName = value
								@isJar = true
							elsif @enableApexScan && value.include?(".apex") then
								@currentResult.apexName = value
								@isApex = true
							end
						end
					when DEF_APK_OPTIMIZE_IDENTIFIER
						if @enableApkScan && value then
							if value.to_s.downcase == "disabled" then
								@currentResult.optimizeEnabled = false
							else
								@currentResult.optimizeEnabled = value
							end
						end
					else
						if @enableNativeScan then
							DEF_CFLAGS_IDENTIFIER.each do | aCFlags |
								if aCFlags == key then
									val = value.to_s.split("\\").map(&:strip!)
									val.each do |aVal|
										if aVal then
											@currentResult.cflags << aVal
										end
									end
									break
								end
							end
						end
						if @enableJarScan then
							DEF_JAR_IDENTIFIER.each do | anIdentifier |
								if theLine.match(anIdentifier) then
									@currentResult.jarName = @currentResult.builtOuts.last if @currentResult.builtOuts.last
									@isJar = true
								end
							end
						end
					end
				end

				theLine = ""
			end
		end

		ensureNativeIncludes()
		_envEnsure()
		ensureCompilerOption()
	end


	def initialize(makefilePath, envFlatten, compilerFilter, enableNativeScan = true, enableApkScan = true, enableJarScan = true, enableApexScan = true)
		super(makefilePath, envFlatten, compilerFilter, enableNativeScan, enableApkScan, enableJarScan, enableApexScan)

		@env = {}
		@env["call my-dir"] = FileUtil.getDirectoryFromPath(@makefilePath)
		makefileBody = FileUtil.readFileAsArray(makefilePath)
		targetIdentifiers = DEF_NATIVE_LIB_IDENTIFIER | DEF_APK_IDENTIFIER | DEF_JAR_IDENTIFIER # APEX by Android.mk?
		targetIdentifiers.each do | aCondition |
			result = makefileBody.grep(aCondition)
			if !result.empty? then
				# found native lib
				@isNativeLib = true if @enableNativeScan && DEF_NATIVE_LIB_IDENTIFIER.include?(aCondition)
				@isApk = true if @enableApkScan && DEF_APK_IDENTIFIER.include?(aCondition)
				@isJar = true if @enableJarScan && DEF_JAR_IDENTIFIER.include?(aCondition)
				@isApex = false
				#break
			end
		end
		parseMakefile(makefileBody) if @isNativeLib || @isApk || @isJar
	end

	def dump
		return "path:#{@makefilePath}, nativeLib:#{@isNativeLib ? "true" : "false"}, builtOuts:#{@builtOuts.to_s}, includes:#{@nativeIncludes.to_s}"
	end
end



class AndroidBpParser < AndroidMakefileParser
	DEF_DEFAULTS_IDENTIFIER = "defaults"
	DEF_DEFAULTS_IDENTIFIERS = [
		"cc_defaults",
		"java_defaults",
		"rust_defaults",
		"apex_defaults"
	]
	DEF_NATIVE_LIB_IDENTIFIER=[
		"cc_library",
		"cc_library_shared",
		"cc_library_static"
	]

	DEF_NAME_IDENTIFIER = "name"
	DEF_INCLUDE_DIRS = [
		"export_include_dirs",
		"header_libs",
		"export_header_lib_headers",
		"include_dirs",
		"local_include_dirs",
	]

	DEF_COMPILE_OPTION = "cflags"

	DEF_APK_IDENTIFIER = [
		"android_app",
		"android_app_import",
		"runtime_resource_overlay"
	]
	DEF_APK_NAME_IDENTIFIER = "name"
	DEF_APK_DEFAULTS_IDENTIFIER = "defaults" # [], makefile base
	DEF_APK_DEPENDENCIES_IDENTIFIER = [
		"static_libs" # []
	]
	DEF_CERTIFICATE_IDENTIFIER = "certificate"
	DEF_APK_PRIVILEGED_IDENTIFIER = "privileged"
	DEF_APK_PLATFORM_API_IDENTIFIER = "platform_apis"

	DEF_APK_OPTIMIZE_IDENTIFIER = "optimize"
	DEF_APK_OPTIMIZE_ENABLED_IDENTIFIER = "enabled"
	DEF_APK_OPTIMIZE_SHRINK_IDENTIFIER = "shrink"

	DEF_DEX_PREOPT_IDENTIFIER = "dex_preopt"
	DEF_DEX_PREOPT_ENABLED_IDENTIFIER = "enabled"

	DEF_JAR_IDENTIFIER = [
		"java_library_static",
		"java_library",
		"java_sdk_library",
		"android_library"
	]
	DEF_JAR_NAME_IDENTIFIER = "name"

	DEF_APEX_IDENTIFIER = ["module_apex"]
	DEF_APEX_NAME_IDENTIFIER = "name"


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

	def getCorrespondingDefaults(body, targetDefaults)
		result = {}

		DEF_DEFAULTS_IDENTIFIERS.each do |aCondition|
			pos = body.index(aCondition)
			if pos then
				theBody = StrUtil.getBlacket(body, "{", "}", pos)
				ensuredJson = ensureJson(theBody)

				theBp = {}
				begin
					theBp = JSON.parse(ensuredJson)
				rescue => ex

				end
				if theBp.has_key?(DEF_NAME_IDENTIFIER) then
					if theBp[DEF_NAME_IDENTIFIER] == targetDefaults then
						result = theBp
						break
					end
				end
			end
		end

		return result
	end

	def ensureDefaults(body, theBp)
		result = theBp

		if theBp.has_key?(DEF_DEFAULTS_IDENTIFIER) then
			defaults = theBp[DEF_DEFAULTS_IDENTIFIER]
			defaults.each do |aDefault|
				theDefault = getCorrespondingDefaults(body, aDefault)
				theDefault.delete( DEF_NAME_IDENTIFIER )
				theBp.delete( DEF_DEFAULTS_IDENTIFIER )
				#theBp = theBp.merge( theDefault )
				theDefault.each do |key,value|
					if !theBp.has_key?(key) then
						theBp[key] = value
					else
						if value.kind_of?(Array) && theBp[key].kind_of?(Array) then
							theBp[key] = theBp[key] | value
						elsif value.kind_of?(Hash) && theBp[key].kind_of?(Hash) then
							theBp[key] = theBp[key].merge( value )
						end
					end
				end
			end
			result = theBp
		end

		return result
	end


	def parseMakefile(makefileBody)
		body = removeRemark(makefileBody).join(" ")

		targetIdentifier = []
		targetIdentifier = targetIdentifier | DEF_NATIVE_LIB_IDENTIFIER if @enableNativeScan
		targetIdentifier = targetIdentifier | DEF_APK_IDENTIFIER if @enableApkScan
		targetIdentifier = targetIdentifier | DEF_JAR_IDENTIFIER if @enableJarScan
		targetIdentifier = targetIdentifier | DEF_APEX_IDENTIFIER if @enableApexScan

		targetIdentifier.each do |aCondition|
			pos = body.index(aCondition)
			if pos then
				theBody = StrUtil.getBlacket(body, "{", "}", pos)
				ensuredJson = ensureJson(theBody)

				theBp = {}
				begin
					theBp = JSON.parse(ensuredJson)
				rescue => ex

				end
				if !theBp.empty? then
					theBp = ensureDefaults(body, theBp)

					@currentResult.builtOuts << theBp[DEF_NAME_IDENTIFIER] if theBp.has_key?(DEF_NAME_IDENTIFIER)

					if @enableNativeScan && DEF_NATIVE_LIB_IDENTIFIER.include?(aCondition) then
						@isNativeLib = true
						DEF_INCLUDE_DIRS.each do |anIncludeIdentifier|
							if theBp.has_key?(anIncludeIdentifier) then
								theBp[anIncludeIdentifier].to_a.each do |anInclude|
									anInclude.to_s.strip!
									anInclude = anInclude.slice(0, anInclude.length-1) if anInclude.end_with?(".")
									if !anInclude.empty? then
										theLibIncludePath = getRobustPath(@makefileDirectory, anInclude)
										@currentResult.nativeIncludes << theLibIncludePath if File.exist?(theLibIncludePath)
										theLibIncludePath = getRobustPath(@androidRootPath, anInclude)
										@currentResult.nativeIncludes << theLibIncludePath if File.exist?(theLibIncludePath)
									end
								end
							end
						end

						if theBp.has_key?(DEF_COMPILE_OPTION) then
							theBp[DEF_COMPILE_OPTION].to_a.each do |anOption|
								anOption = anOption.to_s.strip
								@currentResult.cflags << anOption if !anOption.empty?
							end
						end
					elsif @enableApkScan && DEF_APK_IDENTIFIER.include?(aCondition) then
						@isApk = true
						if theBp.has_key?(DEF_DEX_PREOPT_IDENTIFIER) then
							val = theBp[DEF_DEX_PREOPT_IDENTIFIER]
							if val.has_key?(DEF_DEX_PREOPT_ENABLED_IDENTIFIER) then
								enabled = val[DEF_DEX_PREOPT_ENABLED_IDENTIFIER].to_s
								@currentResult.dexPreOpt = enabled if enabled
							end
						end
						if theBp.has_key?(DEF_APK_NAME_IDENTIFIER) then
							val = theBp[DEF_APK_NAME_IDENTIFIER].to_s
							@currentResult.apkName = val if val
						end
						if theBp.has_key?(DEF_CERTIFICATE_IDENTIFIER) then
							val = theBp[DEF_CERTIFICATE_IDENTIFIER].to_s
							@currentResult.certificate = val if val
						end
						if theBp.has_key?(DEF_APK_OPTIMIZE_IDENTIFIER) then
							val = theBp[DEF_APK_OPTIMIZE_IDENTIFIER]
							if val.has_key?(DEF_APK_OPTIMIZE_ENABLED_IDENTIFIER) then
								theVal = val[DEF_APK_OPTIMIZE_ENABLED_IDENTIFIER].to_s
								@currentResult.optimizeEnabled = theVal if theVal
							end
							if val.has_key?(DEF_APK_OPTIMIZE_SHRINK_IDENTIFIER) then
								theVal = val[DEF_APK_OPTIMIZE_SHRINK_IDENTIFIER].to_s
								@currentResult.optimizeShrink = theVal if theVal
							end
						end
					elsif @enableJarScan && DEF_JAR_IDENTIFIER.include?(aCondition) then
						@isJar = true
						if theBp.has_key?(DEF_JAR_NAME_IDENTIFIER) then
							val = theBp[DEF_JAR_NAME_IDENTIFIER].to_s
							@currentResult.jarName = val if val
						end
						if theBp.has_key?(DEF_CERTIFICATE_IDENTIFIER) then
							val = theBp[DEF_CERTIFICATE_IDENTIFIER].to_s
							@currentResult.certificate = val if val

						end
						if theBp.has_key?(DEF_DEX_PREOPT_IDENTIFIER) then
							val = theBp[DEF_DEX_PREOPT_IDENTIFIER]
							if val.has_key?(DEF_DEX_PREOPT_ENABLED_IDENTIFIER) then
								enabled = val[DEF_DEX_PREOPT_ENABLED_IDENTIFIER].to_s
								@currentResult.dexPreOpt = enabled if enabled
							end
						end
					elsif @enableApexScan && DEF_APEX_IDENTIFIER.include?(aCondition) then
						@isApex = true
						if theBp.has_key?(DEF_APEX_NAME_IDENTIFIER) then
							val = theBp[DEF_APEX_NAME_IDENTIFIER].to_s
							@currentResult.apexName = val if val
						end
						if theBp.has_key?(DEF_CERTIFICATE_IDENTIFIER) then
							val = theBp[DEF_CERTIFICATE_IDENTIFIER].to_s
							@currentResult.certificate = val if val

						end
					end
				end
				@currentResult = ParseResult.new()
				@results << @currentResult
			end
		end

		ensureNativeIncludes()
		ensureCompilerOption()
	end

	def initialize(makefilePath, envFlatten, compilerFilter, enableNativeScan = true, enableApkScan = true, enableJarScan = true, enableApexScan = true)
		super(makefilePath, envFlatten, compilerFilter, enableNativeScan, enableApkScan, enableJarScan, enableApexScan)

		makefileBody = FileUtil.readFileAsArray(makefilePath)
		parseMakefile(makefileBody)
	end

	def dump
		return "path:#{@makefilePath}, nativeLib:#{@isNativeLib ? "true" : "false"}, builtOuts:#{@builtOuts.to_s}, includes:#{@nativeIncludes.to_s}"
	end
end


class Reporter
	def setupOutStream(reportOutPath, enableAppend = false)
		outStream = reportOutPath ? FileUtil.getFileWriter(reportOutPath, enableAppend) : nil
		outStream = outStream ? outStream : STDOUT
		@outStream = outStream
	end

	def initialize(reportOutPath, enableAppend = false)
		setupOutStream(reportOutPath, enableAppend)
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
	def initialize(reportOutPath, enableAppend = false)
		super(reportOutPath, enableAppend)
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
	def initialize(reportOutPath, enableAppend = false)
		super(reportOutPath, enableAppend)
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
	def initialize(reportOutPath, enableAppend = false)
		super(reportOutPath, enableAppend)
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
	def initialize(reportOutPath, enableAppend=false)
		@reportOutPath = reportOutPath
		@outStream = nil #not necessary to call super()
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
			mainVal = nil
			if mainKey then
				mainVal = aData.has_key?(mainKey) ? aData[mainKey] : "library"

				if mainVal.kind_of?(Array) then
					mainVal = mainVal[0]
				end

				aData.delete(mainKey)

				baseDir = @reportOutPath.to_s.include?(".xml") ? FileUtil.getDirectoryFromPath(@reportOutPath) : @reportOutPath
				reportPath = "#{baseDir}/#{mainVal}.xml"
			end
			if mainVal then
				FileUtil.ensureDirectory( FileUtil.getDirectoryFromPath(reportPath) )
				setupOutStream( reportPath )
				_subReport(aData, 0)
				@outStream.close() if @outStream!=STDOUT
			end
		end
	end
end

class CompilerFilter
	def self.filterOption(options)
		return options
	end
end

class CompilerFilterGcc < CompilerFilter
	DEF_NOT_SUPPORTED_CFLAGS=[
		"-fstandalone-debug",
		"-Wthread-safety",
		"-Wexit-time-destructors",
		"-fno-c++-static-destructors",
		"-ftrivial-auto-var-init",
		"-funused-private-field",
		"-fno-unused-argument",
		"-fno-nullability-completeness",
		"-Wshadow-",
		"-Wno-implicit-fallthrough"
	]
	def self.filterOption(options)
		result = []
		options.each do |anOption|
			anOption.strip!
			DEF_NOT_SUPPORTED_CFLAGS.each do |anUnsupportedFlag|
				if anOption.start_with?(anUnsupportedFlag) then
					anOption = nil
					break
				end
			end

			result << anOption if anOption
		end
		result.uniq!
		return result
	end
end

class CompilerFilterClang < CompilerFilter
	def self.filterOption(options)
		return options
	end
end


class AndroidMakefileParserExecutor < TaskAsync
	def initialize(resultCollector, makefilePath, version, envFlatten, compilerFilter, isNativeLib, isApk, isJar, isApex)
		super("AndroidMakefileParserExecutor #{makefilePath}")
		@resultCollector = resultCollector
		@makefilePath = makefilePath.to_s
		@version = version
		@envFlatten = envFlatten
		@compilerFilter = compilerFilter
		@isNativeLib = isNativeLib
		@isApk = isApk
		@isJar = isJar
		@isApex = isApex
	end

	def execute
		parser = @makefilePath.end_with?(".mk") ? AndroidMkParser.new( @makefilePath, @envFlatten, @compilerFilter, @isNativeLib, @isApk, @isJar ) : AndroidBpParser.new( @makefilePath, @envFlatten, @compilerFilter, @isNativeLib, @isApk, @isJar, @isApex )
		results = parser.getResults(@version)
		@resultCollector.onResult(@makefilePath, results) if results && !results.empty?
		_doneTask()
	end
end


#---- main --------------------------
options = {
	:verbose => false,
	:mode => "nativeLib|apk|jar|apex",
	:libFields => "libName|version|headers|libs|gcc_options",
	:apkFields => "apkName|apkPath|certificate|dexPreOpt",
	:jarFields => "jarName|jarPath",
	:apexFields => "apexName|apexPath",
	:envFlatten => false,
	:reportFormat => "xml",
	:outFolder => nil,
	:filterOutMatch => false,
	:reportOutPath => nil,
	:version => nil,
	:compiler => "gcc",
	:numOfThreads => TaskManagerAsync.getNumberOfProcessor()
}

reporter = XmlReporter
resultCollector = ResultCollectorHash.new()

opt_parser = OptionParser.new do |opts|
	opts.banner = "Usage: usage ANDROID_HOME"

	opts.on("-m", "--mode=", "Set analysis modes nativLib|apk|jar|apex (default:#{options[:mode]})") do |mode|
		options[:mode] = mode.to_s
	end

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

	opts.on("", "--libFields=", "Specify lib report fields (default:#{options[:libFields]})") do |libFields|
		options[:libFields] = libFields
	end

	opts.on("", "--apkFields=", "Specify apk custom fields (default:#{options[:apkFields]})") do |apkFields|
		options[:apkFields] = apkFields
	end

	opts.on("", "--jarFields=", "Specify jar custom fields (default:#{options[:jarFields]})") do |jarFields|
		options[:jarFields] = jarFields
	end

	opts.on("", "--apexFields=", "Specify apex custom fields (default:#{options[:apexFields]})") do |apexFields|
		options[:apexFields] = apexFields
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

	opts.on("-c", "--compiler=", "Specify if you want to filter non supported flags. gcc|clang (default:#{options[:compiler]})") do |compiler|
		case compiler.to_s.downcase
		when "gcc","clang"
			options[:compiler] = compiler
		end
	end

	opts.on("-j", "--numOfThreads=", "Specify number of threads to analyze (default:#{options[:numOfThreads]})") do |numOfThreads|
		numOfThreads = numOfThreads.to_i
		options[:numOfThreads] = numOfThreads if numOfThreads
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

isNative = options[:mode].include?("nativeLib")
isApk = options[:mode].include?("apk")
isJar = options[:mode].include?("jar")
isApex = options[:mode].include?("apex")

builtOuts = []
if options[:outFolder] then
	builtOuts = AndroidUtil.getListOfBuiltOuts(options[:outFolder], isNative, isApk, isJar, isApex)
end

puts makefilePaths if options[:verbose]

compilerFilter = options[:compiler] == "gcc" ? CompilerFilterGcc : CompilerFilterClang

result = []
taskMan = ThreadPool.new( options[:numOfThreads].to_i )
makefilePaths.each do | aMakefilePath |
	taskMan.addTask( AndroidMakefileParserExecutor.new( resultCollector, aMakefilePath, options[:version], options[:envFlatten], compilerFilter, isNative, isApk, isJar, isApex ) )
end
taskMan.executeAll()
taskMan.finalize()
_result = resultCollector.getResult()
_result = _result.sort

_result.each do | makefilePath, theResults |
	theResults.each do |aResult|
		aResult["makefile"] = makefilePath
	end
	result = result | theResults # note that theResults is also array
end

if !builtOuts.empty? then
	result = AndroidMakefileParser.replacePathWithBuiltOuts( result, builtOuts, options[:filterOutMatch] )
end

nativeLibs = []
apks = []
jars = []
apexs = []
result.each do |aResult|
	# ensure "libs" for native lib and ensure "apkPath" for apk
	aResult["libs"] = []
	aResult["jarPath"] = []
	aResult["apexPath"] = []
	aResult["builtOuts"] = aResult["builtOuts"].to_a
	aResult["builtOuts"].each do |aBuiltOut|
		aBuiltOut = aBuiltOut.to_s
		filename = FileUtil.getFilenameFromPath(aBuiltOut)
		aResult["libs"] << aBuiltOut if aBuiltOut.end_with?(".so") || filename.start_with?("lib")
		aResult["apexPath"] << aBuiltOut if aBuiltOut.end_with?(".apex")
		aResult["jarPath"] << aBuiltOut if aBuiltOut.end_with?(".jar") || !filename.include?(".")
	end
	aResult["libs"].uniq!
	aResult["jarPath"].uniq!
	aResult["apexPath"].uniq!
	aResult["apkPath"] = (aResult["builtOuts"] - aResult["libs"] - aResult["jarPath"] - aResult["apexPath"] ).uniq # then apkPath is only apks as of now.

	# for nativeLibs
	if aResult.has_key?("libName") && !aResult["libName"].empty? && !aResult["libs"].empty? then
		nativeLibs << aResult
	end

	# for apks
	if aResult.has_key?("apkName") && !aResult["apkName"].empty? && !aResult["apkPath"].empty? then
		# ensure dexPreOpt
		if !aResult.has_key?("dexPreOpt") || aResult["dexPreOpt"].empty? then
			aResult["dexPreOpt"] = "true" # default is true
		end
		apks << aResult
	end

	# for jars
	if aResult.has_key?("jarName") && !aResult["jarName"].empty? then
		jars << aResult
	end

	# for apexs
	if aResult.has_key?("apexName") && !aResult["apexName"].empty? then
		apexs << aResult
	end
end

if reporter == XmlReporterPerLib then
	FileUtil.ensureDirectory( options[:reportOutPath] )
end

isMultipleReports = !options[:mode].split("|").empty?
if isNative then
	_reporter = reporter.new( options[:reportOutPath] )
	_reporter.report( nativeLibs, options[:libFields], options )
	_reporter.close()
end

if isApk then
	_reporter = reporter.new( options[:reportOutPath], isMultipleReports )
	_reporter.report( apks, options[:apkFields], options )
	_reporter.close()
end

if isJar then
	_reporter = reporter.new( options[:reportOutPath], isMultipleReports )
	_reporter.report( jars, options[:jarFields], options )
	_reporter.close()
end

if isApex then
	_reporter = reporter.new( options[:reportOutPath], isMultipleReports )
	_reporter.report( apexs, options[:apexFields], options )
	_reporter.close()
end
