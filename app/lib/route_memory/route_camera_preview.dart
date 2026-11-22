import 'package:flutter/widgets.dart';

import 'route_platform_profile.dart';

/// Native route camera preview. Same view type on both platforms; Android
/// hosts a CameraX PreviewView, iOS an AVCaptureVideoPreviewLayer.
const routeCameraPreviewViewType = 'hk.pathguide/route_camera/preview';

Widget routeCameraPreview() => RoutePlatform.isAndroid
    ? const AndroidView(viewType: routeCameraPreviewViewType)
    : const UiKitView(viewType: routeCameraPreviewViewType);
