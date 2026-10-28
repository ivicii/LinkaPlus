import SwiftUI
import MapKit

/// A plain MKMapView wrapper — more reliable than SwiftUI's Map on iOS 16 for a
/// single stable pin plus the user's location dot (no annotation churn/flicker).
struct LockMapView: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D
    let title: String
    var route: [CLLocationCoordinate2D] = []

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.pointOfInterestFilter = .excludingAll
        map.setRegion(
            MKCoordinateRegion(center: coordinate,
                               span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)),
            animated: false)
        let ann = MKPointAnnotation()
        ann.coordinate = coordinate
        ann.title = title
        map.addAnnotation(ann)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        if let pin = map.annotations.first(where: { $0 is MKPointAnnotation }) as? MKPointAnnotation,
           pin.coordinate.latitude != coordinate.latitude || pin.coordinate.longitude != coordinate.longitude {
            pin.coordinate = coordinate
            map.setCenter(coordinate, animated: true)
        }

        // Redraw route overlay if it changed.
        let existing = map.overlays.compactMap { $0 as? MKPolyline }
        if existing.count != (route.count > 1 ? 1 : 0) {
            map.removeOverlays(map.overlays)
            if route.count > 1 {
                map.addOverlay(MKPolyline(coordinates: route, count: route.count))
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = .systemBlue
                r.lineWidth = 4
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil } // keep default blue dot
            let id = "lock"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.markerTintColor = .systemRed
            view.glyphImage = UIImage(systemName: "bicycle")
            view.canShowCallout = true
            return view
        }
    }
}
