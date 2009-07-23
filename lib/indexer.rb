require 'rubygems/indexer'

module Gem
  class Indexer
    def update_specs_index(index, source, dest)
      specs_index = Marshal.load Gem.read_binary(source)

      index.each do |_, spec|
        platform = spec.original_platform
        platform = Gem::Platform::RUBY if platform.nil? or platform.empty?
        specs_index << [spec.name, spec.version, platform]
      end

      specs_index = compact_specs specs_index.uniq

      open dest, 'wb' do |io|
        Marshal.dump specs_index, io
      end
    end

    def update_index(source_index = nil)
      make_temp_directories

      #specs_mtime = File.mtime(@dest_specs_index)
      #newest_mtime = Time.at 0

      #updated_gems = gem_file_list.select do |gem|
        #gem_mtime = File.mtime(gem)
        #newest_mtime = gem_mtime if gem_mtime > newest_mtime
        #gem_mtime >= specs_mtime
      #end

      #if updated_gems.empty? then
        #say 'No new gems'
        #terminate_interaction 0
      #end

      newest_mtime = Time.now
      index = source_index || Marshal.load(File.open(File.join(@dest_directory, "source_index")))

      Gem.time 'Updated indexes' do
        update_specs_index index, @dest_specs_index, @specs_index
        update_specs_index index, @dest_latest_specs_index, @latest_specs_index
        update_specs_index(index.prerelease_gems, @dest_prerelease_specs_index,
                           @prerelease_specs_index)
      end

      compress_indicies

      files = []
      files << @specs_index
      files << "#{@specs_index}.gz"
      files << @latest_specs_index
      files << "#{@latest_specs_index}.gz"
      files << @prerelease_specs_index
      files << "#{@prerelease_specs_index}.gz"

      files = files.map do |path|
        path.sub @directory, ''
      end

      files.each do |file|
        src_name = File.join @directory, file
        dst_name = File.join @dest_directory, File.dirname(file)

        FileUtils.mv src_name, dst_name, :force => true
        File.utime newest_mtime, newest_mtime, dst_name
      end
    end
  end
end
