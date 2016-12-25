#!/usr/bin/env ruby
# encoding: utf-8

# https://github.com/jawj/iphoto-flickr

# Copyright (c) George MacKerron 2013, http://mackerron.com
# Released under GPLv3: http://opensource.org/licenses/GPL-3.0
# modified by Jorge SMM (jorsmm@gmail.com)

%w{flickraw-cached tempfile fileutils yaml}.each { |lib| require lib }

require 'plist'
require 'term/ansicolor'

include Term::ANSIColor

system("clear")
print on_green, "                      Flickrbackup.                   ", reset, "\n"

# own records setup
dataDirName = File.expand_path "~/Library/Application Support/flickrbackup"
FileUtils.mkpath dataDirName

class PersistedIDsHash  # in retrospect, perhaps this was a job for SQLite ...
  ID_SEP = ' -> '
  def initialize(fileName)

puts "#{fileName}"

    @hash = {}
    FileUtils.touch fileName
    open(fileName).each_line do |line|
      k, v = line.chomp.split ID_SEP
      store k, v
    end
    open(fileName, 'a') do |file|
      @file = file
      yield self
    end
  end
  def add(k, v)
    store k, v
    record = "#{k}#{ID_SEP}#{v}"
    @file.puts record
    @file.fsync
    record
  end
  def get(k)
    @hash[k]
  end
  def getHash()
    @hash
  end
private
  def store(k, v)
    @hash[k] = v
  end
end

class PersistedIDsHashMany < PersistedIDsHash
  def associated?(k, v)
    @hash[k] && @hash[k][v]
  end
private
  def store(k, v)
    (@hash[k] ||= {})[v] = true
  end
end


puts "---------------#{Time.new.inspect}--------------"
print blue, "> Authenticating in Flickr...", reset, "\n"
# Flickr API setup

FlickRaw.secure = true

credentialsFileName = "#{dataDirName}/credentials.yaml"

if File.exist? credentialsFileName
  credentials = YAML.load_file credentialsFileName
  FlickRaw.api_key        = credentials[:api_key]
  FlickRaw.shared_secret  = credentials[:api_secret]
  flickr.access_token     = credentials[:access_token]
  flickr.access_secret    = credentials[:access_secret]
  login = flickr.test.login
  print green, "> Authenticated as: #{login.username}", reset, "\n"

else
  print yellow, "Flickr API key: ", reset
  FlickRaw.api_key = gets.strip

  print yellow, "Flickr API shared secret: ", reset
  FlickRaw.shared_secret = gets.strip

  token = flickr.get_request_token
  auth_url = flickr.get_authorize_url(token['oauth_token'], :perms => 'write')
  print yellow, "Authorise access to your Flickr account: press [Return] when ready", reset
  gets
  `open '#{auth_url}'`

  print yellow, "Authorisation code: ", reset
  verify = gets.strip
  flickr.get_access_token(token['oauth_token'], token['oauth_token_secret'], verify)
  login = flickr.test.login
  print green, "Authenticated as: #{login.username}", reset, "\n"

  credentials = {api_key:       FlickRaw.api_key,
                 api_secret:    FlickRaw.shared_secret,
                 access_token:  flickr.access_token,
                 access_secret: flickr.access_secret}

  File.open(credentialsFileName, 'w') { |credentialsFile| YAML.dump(credentials, credentialsFile) }
end

def rateLimit
  startTime = Time.now
  returnValue = yield
  timeTaken = Time.now - startTime
  timeToSleep = 1.01 - timeTaken  # rate limit to just under 3600 reqs/hour
  sleep timeToSleep if timeToSleep > 0
  returnValue
end

# load own backup records
puts "---------------#{Time.new.inspect}--------------"
print blue, "> Reading backup files...", reset, "\n"

PersistedIDsHash.new("#{dataDirName}/uploaded-photo-ids-map.txt") do |uploadedPhotos|
PersistedIDsHash.new("#{dataDirName}/created-album-ids-map.txt") do |createdEvents|
PersistedIDsHashMany.new("#{dataDirName}/photos-in-album-ids-map.txt") do |photosInEvents|
PersistedIDsHash.new("#{dataDirName}/geoed-photo-ids-map.txt") do |geoedPhotos|

# parse AlbumData.xml
puts "---------------#{Time.new.inspect}--------------"
albumDataFilePath = File.expand_path "~/Pictures/iPhoto Library.photolibrary/AlbumData.xml" 
print blue, "> Reading iPhoto Library file:\n", reset, blink, albumDataFilePath , reset
result = Plist::parse_xml(albumDataFilePath)
#print result.keys
print "\r", albumDataFilePath, "\n"

# get all iPhoto IDs and paths, and filter out those already backed up
puts "---------------#{Time.new.inspect}--------------"
print blue, "> Calculating Number of photos/events ...", reset, "\n"
allPhotoData = []
allGeoPhotoData = []
listOfPhotos = result["Master Image List"]
listOfPhotos.each do |m|
  photoId = m[0]
  photoData = m[1]
#  puts "#{photoId}, #{photoData}"
  photoPathFile = photoData["ImagePath"]
  photoFallbackPathFile = photoData["OriginalPath"]
  latitude = photoData["latitude"]
  longitude = photoData["longitude"]

  next if photoPathFile.end_with? ".MOV"
  next if photoPathFile.end_with? ".mov"
  next if photoPathFile.end_with? ".MP4"
  next if photoPathFile.end_with? ".mp4"

  neededPhotoData = [photoId, photoPathFile, photoFallbackPathFile ]
  allPhotoData << neededPhotoData
  if latitude != nil
      #  puts "#{photoId}, #{photoData}"

      neededGeoPhotoData = [photoId, photoPathFile, photoFallbackPathFile, latitude, longitude ]
      allGeoPhotoData << neededGeoPhotoData
  end
end

newPhotoData = allPhotoData.reject { |photoData| uploadedPhotos.get photoData.first }
newGeoPhotoData = allGeoPhotoData.reject { |photoData| geoedPhotos.get photoData.first }

#puts "#{allPhotoData} \n\n"
#puts "#{newPhotoData} \n\n"

# get all iPhoto albums and associated photo IDs

numeroFotosEnEventos = 0
numeroEventos = 0
eventData = {}
listOfAlbums = result["List of Albums"]
listOfAlbums = listOfAlbums.select { |k| k["Album Type"] == "Event" }
sortedListOfAlbums = listOfAlbums.sort_by { |k| k["ProjectEarliestDateAsTimerInterval"].to_i }
sortedListOfAlbums.each do |m|
  if m["Album Type"] == "Event" 
    numeroEventos=numeroEventos+1
    #puts "#{m["AlbumId"]},#{m["AlbumName"]},#{m["KeyPhotoKey"]},#{m["PhotoCount"]}"
    albumId = m["AlbumId"]
    keyPhotoKey = m["KeyPhotoKey"]
    albumName = m["AlbumName"]
    eventData[albumId] = {name: albumName, keyPhotoKey: keyPhotoKey, photoIDs: []}
    albumPhotoIds = eventData[albumId][:photoIDs]
    m["KeyList"].each do |p|
      albumPhotoIds << p
      numeroFotosEnEventos=numeroFotosEnEventos+1
    end
#    puts "#{eventData}"
  end
end

puts ""
puts "   #{allPhotoData.length} photos (and videos) in iPhoto library"
print on_green,"   #{newPhotoData.length} photos (not MOV/mp4) not yet uploaded to Flickr", reset, "\n"
puts "   #{listOfAlbums.count} Events in iPhoto library"
puts "   #{createdEvents.getHash().length} Events already created in Flickr" 
puts "   #{photosInEvents.getHash().length} Photos in Events already uploaded in Flickr"
puts "   #{allGeoPhotoData.length} Photos with GEO info in iPhoto Library"
print on_green, "   #{newPhotoData.length} photos not yet GEOed to Flickr", reset, "\n"
puts ""

# upload new files
puts "---------------#{Time.new.inspect}--------------"
print on_blue, "> 1/3 Uploading new Photos...                         ", reset, "\n"

MAX_SIZE = 1024 ** 3
MAX_RETRY = 30

class ErrTooBig < RuntimeError; def to_s; 'File is too big'; end; end

newPhotoData.each_with_index do |photoData, i|
  iPhotoID, photoPath, fallbackPhotoPath = photoData
  photoPath = fallbackPhotoPath unless File.exist? photoPath  # fall back to 'image path' if 'original path' missing

  retries = 0

  begin

    next if photoPath == nil
    next if photoPath.end_with? ".MOV"
    next if photoPath.end_with? ".mov"
    next if photoPath.end_with? ".MP4"
    next if photoPath.end_with? ".mp4"

    print "#{i + 1}. Uploading[#{iPhotoID}] '#{photoPath}' ... "

    raise ErrTooBig if File.size(photoPath) > MAX_SIZE
    flickrID = rateLimit { flickr.upload_photo photoPath }
    raise 'Invalid Flickr ID returned' unless flickrID.is_a? String  # this can happen, but I'm not yet sure what it means
    puts uploadedPhotos.add iPhotoID, flickrID

  rescue ErrTooBig, Errno::ENOENT, Errno::EINVAL => e  # in the face of missing/large/weird files, don't retry
    print red, e, reset, "\n"
    puts

  # keep trying in face of network errors: Timeout::Error, Errno::BROKEN_PIPE, SocketError, ...
  rescue => err
    if photoPath == nil
      retries = MAX_RETRY
    else
      if photoPath.end_with? ".MOV"
        retries = MAX_RETRY
      end
      if photoPath.end_with? ".mov"
        retries = MAX_RETRY
      end
    end
    retries += 1
    if retries > MAX_RETRY
      print on_red, "skipped: retry count exceeded", reset, "\n"
    else
      print red, "#{err.message}: retrying in 10s ", reset; 10.times { sleep 1; print '.' }; puts
      retry
    end
  end

end


# update GEO info
puts "---------------#{Time.new.inspect}--------------"
print on_blue, "> 2/3 Updating GEO info in Photos...                  ", reset, "\n"
newGeoPhotoData.each_with_index do |photoData, i|
    iPhotoID, photoPath, fallbackPhotoPath, latitude, longitude = photoData
    photoPath = fallbackPhotoPath unless File.exist? photoPath  # fall back to 'image path' if 'original path' missing
    
    retries = 0
    
    begin
        
        next if photoPath.end_with? ".mp4"
        
        print "#{i + 1}. Updating GEO:[#{iPhotoID}] '#{photoPath}' ... "
        
        #https://github.com/khustochka/quails/blob/master/lib/flickraw-cached.rb
        #flickr.photos.geo.setLocation
        #flickr.photos.people.add
        #flickr.photos.setTags
        
        flickrPhotoID = uploadedPhotos.get iPhotoID
        rateLimit { flickr.photos.geo.setLocation(photo_id: flickrPhotoID, lat: latitude.to_s, lon: longitude.to_s) }
        
        puts geoedPhotos.add iPhotoID, latitude.to_s+"#"+longitude.to_s
        
        rescue ErrTooBig, Errno::ENOENT, Errno::EINVAL => e  # in the face of missing/large/weird files, don't retry
        print red, e, reset, "\n"
        puts
        
        # keep trying in face of network errors: Timeout::Error, Errno::BROKEN_PIPE, SocketError, ...
        rescue => err
        if photoPath == nil
            retries = MAX_RETRY
            else
            if photoPath.end_with? ".MOV"
                retries = MAX_RETRY
            end
            if photoPath.end_with? ".mov"
                retries = MAX_RETRY
            end
        end
        retries += 1
        if retries > MAX_RETRY
            print on_red, "skipped: retry count exceeded", reset, "\n"
            else
            print red, "#{err.message}: retrying in 10s ", reset; 10.times { sleep 1; print '.' }; puts
            retry
        end
    end
    
end

# update albums/photosets
puts "---------------#{Time.new.inspect}--------------"
print on_blue, "> 3/3 Updating Events...                              ", reset, "\n"

SET_NOT_FOUND   = 1
PHOTO_NOT_FOUND = 2
PHOTO_ALREADY_IN_ALBUM = 3

eventData.each do |albumID, album|
  photosetID = createdEvents.get(albumID.to_s)

  if photosetID.nil?
    print magenta, "Creating new photoset: '#{album[:name]}' ... ", reset
    keyPhotoKeyID = album[:keyPhotoKey]
    keyPhotoKeyFlickrPhotoID = uploadedPhotos.get keyPhotoKeyID

    begin
      photosetID = rateLimit { flickr.photosets.create(title: album[:name], primary_photo_id: keyPhotoKeyFlickrPhotoID).id }

    rescue FlickRaw::FailedResponse => e
      if e.code == PHOTO_NOT_FOUND  # photoset cannot be created if primary photo has been deleted from Flickr
        print red, e.msg, ' ... ', reset
        photosetID = 'X'
      else raise e
      end
    end

    puts createdEvents.add albumID, photosetID
    photosInEvents.add keyPhotoKeyID.to_s, albumID.to_s
  end

  # add any new photos
  album[:photoIDs].each do |iPhotoID|

    unless photosInEvents.associated? iPhotoID.to_s, albumID.to_s
      flickrPhotoID = uploadedPhotos.get iPhotoID
      print "Adding photo #{iPhotoID} -> #{flickrPhotoID} to photoset #{albumID} -> #{photosetID} ... "
      errorHappened = false

      begin
        rateLimit { flickr.photosets.addPhoto(photoset_id: photosetID, photo_id: flickrPhotoID) }
      rescue FlickRaw::FailedResponse => e
          print red, e.code, reset, "\n"
        if [SET_NOT_FOUND, PHOTO_NOT_FOUND, PHOTO_ALREADY_IN_ALBUM].include? e.code
          print red, e.msg, reset, "\n"
          errorHappened = true
        else raise e
        end
      end

      print green, "done", reset, "\n" unless errorHappened
      photosInEvents.add iPhotoID, albumID
    end
  end

end
puts "---------------#{Time.new.inspect}--------------"
print on_green, "                        Finished.                     ", reset, "\n"

end; end; end; end  # own records blocks
puts  # I prefer some whitespace before the prompt
