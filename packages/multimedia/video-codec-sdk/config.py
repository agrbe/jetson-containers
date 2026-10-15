
def video_codec_sdk(version, nv_codec_headers_tag, default=False):
  """
  NVIDIA Video Codec SDK headers (NVENC/NVDEC) from nv-codec-headers.
  Public source, no login: https://github.com/FFmpeg/nv-codec-headers
  """
  aliases = ['nvenc', 'nvcuvid', 'cuvid']

  pkg = package.copy()
  pkg_name = pkg['name']

  pkg['name'] = f'{pkg_name}:{version}'
  pkg['alias'] = [f'{x}:{version}' for x in aliases]
  pkg['build_args'] = {
      'NV_CODEC_VERSION': version,
      'NV_CODEC_HEADERS_TAG': nv_codec_headers_tag,
  }

  if default:
    pkg['alias'] += [pkg_name] + aliases

  return pkg


# Minimum driver per nv-codec-headers README: n12.2 >= 550.54.14, n13.0 >= 570,
# n13.1 >= 610. JetPack 7.2 ships driver 595, so 13.0 is the newest that works.
package = [
  video_codec_sdk('12.2.72', nv_codec_headers_tag='n12.2.72.0'),
  video_codec_sdk('13.0.19', nv_codec_headers_tag='n13.0.19.1', default=True),
  video_codec_sdk('13.1.15', nv_codec_headers_tag='n13.1.15.0'),
]
