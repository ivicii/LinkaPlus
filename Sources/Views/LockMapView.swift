import SwiftUI
import MapKit

/// A plain MKMapView wrapper — more reliable than SwiftUI's Map on iOS 16 for a
/// single stable pin plus the user's location dot (no annotation churn/flicker).
struct LockMapView: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D
    let title: String

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
        guard let pin = map.annotations.first(where: { $0 is MKPointAnnotation }) as? MKPointAnnotation
        else { return }
        if pin.coordinate.latitude != coordinate.latitude || pin.coordinate.longitude != coordinate.longitude {
            pin.coordinate = coordinate
            map.setCenter(coordinate, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
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
