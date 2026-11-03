# frozen_string_literal: true

require 'digest'

module Cdctl
  module Steam
    Installation = Data.define(:app_id, :name, :root, :library, :manifest_path, :install_path, :build_id,
                               :state_flags, :language, :depots, :compat_data_path, :proton_version) do
      def fully_installed? = state_flags.anybits?(Installation::FULLY_INSTALLED)

      # Changes when any depot of the installed build changes, without hashing hundreds of gigabytes.
      def fingerprint
        parts = [app_id, build_id, *depots.sort.map { |id, manifest| "#{id}:#{manifest}" }]
        Digest::SHA256.hexdigest(parts.join('|'))[0, 16]
      end

      def prefix_path = compat_data_path && File.join(compat_data_path, 'pfx')

      def to_h
        {
          state: 'found', app_id:, name:, steam_root: root, library:, manifest: manifest_path,
          install_dir: install_path, build_id:, build_fingerprint: fingerprint, fully_installed: fully_installed?,
          language:, depots:, compat_data: compat_data_path, prefix: prefix_path, proton_version:
        }
      end
    end
    Installation::FULLY_INSTALLED = 4
  end
end
