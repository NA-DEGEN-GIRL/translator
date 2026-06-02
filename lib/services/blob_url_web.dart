import 'package:web/web.dart' show URL;

void revokeBlobUrlImpl(String url) {
  if (url.startsWith('blob:')) {
    URL.revokeObjectURL(url);
  }
}
