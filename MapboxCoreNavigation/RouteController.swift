import Foundation
import CoreLocation
import MapboxDirections
import Polyline
import MapboxMobileEvents


/**
 The `RouteControllerDelegate` class provides methods for responding to significant occasions during the user’s traversal of a route monitored by a `RouteController`.
 */
@objc(MBRouteControllerDelegate)
public protocol RouteControllerDelegate: class {
    /**
     Returns whether the route controller should be allowed to calculate a new route.
     
     If implemented, this method is called as soon as the route controller detects that the user is off the predetermined route. Implement this method to conditionally prevent rerouting. If this method returns `true`, `routeController(_:willRerouteFrom:)` will be called immediately afterwards.
     
     - parameter routeController: The route controller that has detected the need to calculate a new route.
     - parameter location: The user’s current location.
     - returns: True to allow the route controller to calculate a new route; false to keep tracking the current route.
     */
    @objc(routeController:shouldRerouteFromLocation:)
    optional func routeController(_ routeController: RouteController, shouldRerouteFrom location: CLLocation) -> Bool
    
    /**
     Called immediately before the route controller calculates a new route.
     
     This method is called after `routeController(_:shouldRerouteFrom:)` is called, simultaneously with the `RouteControllerWillReroute` notification being posted, and before `routeController(_:didRerouteAlong:)` is called.
     
     - parameter routeController: The route controller that will calculate a new route.
     - parameter location: The user’s current location.
     */
    @objc(routeController:willRerouteFromLocation:)
    optional func routeController(_ routeController: RouteController, willRerouteFrom location: CLLocation)
    
    /**
     Called immediately after the route controller receives a new route.
     
     This method is called after `routeController(_:willRerouteFrom:)` and simultaneously with the `RouteControllerDidReroute` notification being posted.
     
     - parameter routeController: The route controller that has calculated a new route.
     - parameter route: The new route.
     */
    @objc(routeController:didRerouteAlongRoute:)
    optional func routeController(_ routeController: RouteController, didRerouteAlong route: Route)
    
    /**
     Called when the route controller fails to receive a new route.
     
     This method is called after `routeController(_:willRerouteFrom:)` and simultaneously with the `RouteControllerDidFailToReroute` notification being posted.
     
     - parameter routeController: The route controller that has calculated a new route.
     - parameter error: An error raised during the process of obtaining a new route.
     */
    @objc(routeController:didFailToRerouteWithError:)
    optional func routeController(_ routeController: RouteController, didFailToRerouteWith error: Error)
    
    /**
     Called when the route controller’s location manager receive a location update.
     
     These locations can be modified due to replay or simulation but they can
     also derive from regular location updates from a `CLLocationManager`.
     
     - parameter routeController: The route controller that received the new locations.
     - parameter locations: The locations that were received from the associated location manager.
     */
    @objc(routeController:didUpdateLocations:)
    optional func routeController(_ routeController: RouteController, didUpdateLocations locations: [CLLocation])
}

/**
 A `RouteController` tracks the user’s progress along a route, posting notifications as the user reaches significant points along the route. On every location update, the route controller evaluates the user’s location, determining whether the user remains on the route. If not, the route controller calculates a new route.
 
 `RouteController` is responsible for the core navigation logic whereas 
 `NavigationViewController` is responsible for displaying a default drop-in navigation UI.
 */
@objc(MBRouteController)
open class RouteController: NSObject {
    
    var lastUserDistanceToStartOfRoute = Double.infinity
    
    var lastTimeStampSpentMovingAwayFromStart = Date()
    
    let events = MMEEventsManager.shared()
    
    /**
     The route controller’s delegate.
     */
    public weak var delegate: RouteControllerDelegate?
    
    /**
     The Directions object used to create the route.
     */
    public var directions: Directions
    
    /**
     The route controller’s associated location manager.
     */
    public var locationManager: NavigationLocationManager! {
        didSet {
            oldValue?.delegate = nil
            locationManager.delegate = self
        }
    }
    
    /**
     If true, location updates will be simulated when driving through tunnels or other areas where there is none or bad GPS reception.
     */
    public var isDeadReckoningEnabled = false
    
    /**
     Details about the user’s progress along the current route, leg, and step.
     */
    public var routeProgress: RouteProgress {
        willSet {
            // Save any progress completed up until now
            sessionState.totalDistanceCompleted += routeProgress.distanceTraveled
        }
        didSet {
            // if the user has already arrived and a new route has been set, restart the navigation session
            if sessionState.arrivalTimestamp != nil {
                resetSession()
            } else {
                sessionState.currentRoute = routeProgress.route
            }
            
            var userInfo = [String: Any]()
            if let location = locationManager.location {
                userInfo[MBRouteControllerNotificationLocationKey] = location
            }
            NotificationCenter.default.post(name: RouteControllerDidReroute, object: self, userInfo: userInfo)
        }
    }
    
    /**
     If true, the user puck is snapped to closest location on the route. 
     Defaults to false.
     */
    public var snapsUserLocationAnnotationToRoute = true
    
    var isRerouting = false
    var lastRerouteLocation: CLLocation?
    
    var routeTask: URLSessionDataTask?
    
    /// :nodoc: This is used internally when the navigation UI is being used
    public var usesDefaultUserInterface = false
    
    var sessionState:SessionState
    var outstandingFeedbackEvents = [CoreFeedbackEvent]()
    
    /**
     Intializes a new `RouteController`.
     
     - parameter route: The route to follow.
     - parameter directions: The Directions object that created `route`.
     - parameter locationManager: The associated location manager.
     */
    @objc(initWithRoute:directions:locationManager:)
    public init(along route: Route, directions: Directions = Directions.shared, locationManager: NavigationLocationManager = NavigationLocationManager()) {
        self.sessionState = SessionState(currentRoute: route, originalRoute: route)
        self.directions = directions
        self.routeProgress = RouteProgress(route: route)
        self.locationManager = locationManager
        self.locationManager.activityType = route.routeOptions.activityType
        super.init()
        
        self.locationManager.delegate = self
        self.resumeNotifications()
        self.startEvents(route: route)
        self.resetSession()
    }
    
    deinit {
        suspendLocationUpdates()
        checkAndSendOutstandingFeedbackEvents(forceAll: true)
        sendCancelEvent()
        suspendNotifications()
    }
    
    func startEvents(route: Route) {
        let eventLoggingEnabled = UserDefaults.standard.bool(forKey: NavigationMetricsDebugLoggingEnabled)
        
        var mapboxAccessToken: String? = nil
        if let accessToken = route.accessToken {
            mapboxAccessToken = accessToken
        } else if let path = Bundle.main.path(forResource: "Info", ofType: "plist"),
            let dict = NSDictionary(contentsOfFile: path) as? [String: AnyObject],
            let token = dict["MGLMapboxAccessToken"] as? String {
            mapboxAccessToken = token
        }
        
        if let mapboxAccessToken = mapboxAccessToken {
            events.isDebugLoggingEnabled = eventLoggingEnabled
            events.isMetricsEnabledInSimulator = true
            events.isMetricsEnabledForInUsePermissions = true
            events.initialize(withAccessToken: mapboxAccessToken, userAgentBase: "MapboxEventsNavigationiOS", hostSDKVersion: String(describing: Bundle(for: RouteController.self).object(forInfoDictionaryKey: "CFBundleShortVersionString")!))
            events.disableLocationMetrics()
            events.sendTurnstileEvent()
        } else {
            assert(false, "`accessToken` must be set in the Info.plist as `MGLMapboxAccessToken` or the `Route` passed into the `RouteController` must have the `accessToken` property set.")
        }
    }
    
    func resumeNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(progressDidChange(notification:)), name: RouteControllerProgressDidChange, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(alertLevelDidChange(notification:)), name: RouteControllerAlertLevelDidChange, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(willReroute(notification:)), name: RouteControllerWillReroute, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(didReroute(notification:)), name: RouteControllerDidReroute, object: self)
    }
    
    func suspendNotifications() {
        NotificationCenter.default.removeObserver(self)
    }
    
    /**
     Starts monitoring the user’s location along the route.
     
     Will continue monitoring until `suspendLocationUpdates()` is called.
     */
    public func resume() {
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
    }
    
    /**
     Stops monitoring the user’s location along the route.
     */
    public func suspendLocationUpdates() {
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
    }
    
    /**
     Send feedback about the current road segment/maneuver to the Mapbox data team.
     
     You can pair this with a custom feedback UI in your app to flag problems during navigation
     such as road closures, incorrect instructions, etc. 
     
     With the help of a custom `description` to elaborate on the nature of the problem, using
     this function will automatically flag the road segment/maneuver the user is currently on for 
     closer inspection by Mapbox's system and team.
     
     If you provide a custom feedback UI that lets users elaborate on an 
     issue, you should call this before you show the custom UI so the 
     location and timestamp are more accurate. You can then call 
     `updateLastFeedback()` to attach any additional metadata to the 
     feedback.
     */
    public func recordFeedback(type: FeedbackType, description: String?) {
        enqueueFeedbackEvent(type: type, description: description)
    }
    
    /**
     Update the last recorded feedback event, for example if you have a custom feedback UI that lets a user elaborate on an issue.
     */
    public func updateLastFeedback(type: FeedbackType, description: String?) {
        if let lastFeedback = outstandingFeedbackEvents.map({$0 as? FeedbackEvent}).last {
            lastFeedback?.update(type: type, description: description)
        }
    }
    
    /**
     Discard the last recorded feedback event, for example if you have a custom feedback UI and the user cancelled feedback.
     */
    public func cancelLastFeedback(type: FeedbackType, description: String?) {
        if let lastFeedback = outstandingFeedbackEvents.filter({$0 is FeedbackEvent}).last, let index = outstandingFeedbackEvents.index(of: lastFeedback) {
            outstandingFeedbackEvents.remove(at: index)
        }
    }
}

extension RouteController {
    func progressDidChange(notification: NSNotification) {
        if sessionState.departureTimestamp == nil {
            sessionState.departureTimestamp = Date()
            sendDepartEvent()
        }
        checkAndSendOutstandingFeedbackEvents(forceAll: false)
    }
    
    func alertLevelDidChange(notification: NSNotification) {
        let alertLevel = routeProgress.currentLegProgress.alertUserLevel
        if alertLevel == .arrive && sessionState.arrivalTimestamp == nil {
            sessionState.arrivalTimestamp = Date()
            sendArriveEvent()
        }
    }
    
    func willReroute(notification: NSNotification) {
        enqueueRerouteEvent()
    }
    
    func didReroute(notification: NSNotification) {
        if let lastReroute = outstandingFeedbackEvents.map({$0 as? RerouteEvent }).last {
            lastReroute?.update(newRoute: routeProgress.route)
        }
    }
}

extension RouteController: CLLocationManagerDelegate {
    
    func interpolateLocation() {
        guard let location = locationManager.lastKnownLocation else { return }
        guard let polyline = routeProgress.route.coordinates else { return }
        
        let distance = location.speed as CLLocationDistance
        
        guard let interpolatedCoordinate = coordinate(at: routeProgress.distanceTraveled+distance, fromStartOf: polyline) else {
            return
        }
        
        var course = location.course
        if let upcomingCoordinate = coordinate(at: routeProgress.distanceTraveled+(distance*2), fromStartOf: polyline) {
            course = interpolatedCoordinate.direction(to: upcomingCoordinate)
        }
        
        let interpolatedLocation = CLLocation(coordinate: interpolatedCoordinate,
                                              altitude: location.altitude,
                                              horizontalAccuracy: location.horizontalAccuracy,
                                              verticalAccuracy: location.verticalAccuracy,
                                              course: course,
                                              speed: location.speed,
                                              timestamp: Date())
        
        self.locationManager(self.locationManager, didUpdateLocations: [interpolatedLocation])
    }
    
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            return
        }
        
        delegate?.routeController?(self, didUpdateLocations: [location])
        
        sessionState.pastLocations.push(location)

        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(interpolateLocation), object: nil)
        
        if isDeadReckoningEnabled {
            perform(#selector(interpolateLocation), with: nil, afterDelay: 1.1)
        }
        
        let userSnapToStepDistanceFromManeuver = distance(along: routeProgress.currentLegProgress.currentStep.coordinates!, from: location.coordinate)
        let secondsToEndOfStep = userSnapToStepDistanceFromManeuver / location.speed
        
        guard routeProgress.currentLegProgress.alertUserLevel != .arrive else {
            NotificationCenter.default.post(name: RouteControllerProgressDidChange, object: self, userInfo: [
                RouteControllerProgressDidChangeNotificationProgressKey: routeProgress,
                RouteControllerProgressDidChangeNotificationLocationKey: location,
                RouteControllerProgressDidChangeNotificationSecondsRemainingOnStepKey: secondsToEndOfStep
                ])
            return
        }
        
        // Notify observers if the step’s remaining distance has changed.
        let currentStepProgress = routeProgress.currentLegProgress.currentStepProgress
        let currentStep = currentStepProgress.step
        if let closestCoordinate = closestCoordinate(on: currentStep.coordinates!, to: location.coordinate) {
            let remainingDistance = distance(along: currentStep.coordinates!, from: closestCoordinate.coordinate)
            let distanceTraveled = currentStep.distance - remainingDistance
            if distanceTraveled != currentStepProgress.distanceTraveled {
                currentStepProgress.distanceTraveled = distanceTraveled
                NotificationCenter.default.post(name: RouteControllerProgressDidChange, object: self, userInfo: [
                    RouteControllerProgressDidChangeNotificationProgressKey: routeProgress,
                    RouteControllerProgressDidChangeNotificationLocationKey: location,
                    RouteControllerProgressDidChangeNotificationSecondsRemainingOnStepKey: secondsToEndOfStep
                    ])
            }
        }
        
        let step = routeProgress.currentLegProgress.currentStepProgress.step
        if step.maneuverType == .depart && !userIsOnRoute(location) {
            
            guard let userSnappedDistanceToClosestCoordinate = closestCoordinate(on: step.coordinates!, to: location.coordinate)?.distance else {
                return
            }
            
            // Give the user x seconds of moving away from the start of the route before rerouting
            guard Date().timeIntervalSince(lastTimeStampSpentMovingAwayFromStart) > MaxSecondsSpentTravelingAwayFromStartOfRoute else {
                lastUserDistanceToStartOfRoute = userSnappedDistanceToClosestCoordinate
                return
            }
            
            // Don't check `userIsOnRoute` if the user has not moved
            guard userSnappedDistanceToClosestCoordinate != lastUserDistanceToStartOfRoute else {
                lastUserDistanceToStartOfRoute = userSnappedDistanceToClosestCoordinate
                return
            }
            
            if userSnappedDistanceToClosestCoordinate > lastUserDistanceToStartOfRoute {
                lastTimeStampSpentMovingAwayFromStart = location.timestamp
            }
            
            lastUserDistanceToStartOfRoute = userSnappedDistanceToClosestCoordinate
        }
        
        guard userIsOnRoute(location) || !(delegate?.routeController?(self, shouldRerouteFrom: location) ?? true) else {
            reroute(from: location)
            return
        }
        
        monitorStepProgress(location)
    }
    
    func resetStartCounter() {
        lastTimeStampSpentMovingAwayFromStart = Date()
        lastUserDistanceToStartOfRoute = Double.infinity
    }
    
    /**
     Given a users current location, returns a Boolean whether they are currently on the route.
     
     If the user is not on the route, they should be rerouted.
     */
    public func userIsOnRoute(_ location: CLLocation) -> Bool {
        // Find future location of user
        let metersInFrontOfUser = location.speed * RouteControllerDeadReckoningTimeInterval
        let locationInfrontOfUser = location.coordinate.coordinate(at: metersInFrontOfUser, facing: location.course)
        let newLocation = CLLocation(latitude: locationInfrontOfUser.latitude, longitude: locationInfrontOfUser.longitude)
        let radius = max(RouteControllerMaximumDistanceBeforeRecalculating,
                         location.horizontalAccuracy + RouteControllerUserLocationSnappingDistance)

        let isCloseToCurrentStep = newLocation.isWithin(radius, of: routeProgress.currentLegProgress.currentStep)
        
        // If the user is moving away from the maneuver location
        // and they are close to the next step
        // we can safely say they have completed the maneuver.
        // This is intended to be a fallback case when we do find
        // that the users course matches the exit bearing.
        if let upComingStep = routeProgress.currentLegProgress.upComingStep {
            let isCloseToUpComingStep = newLocation.isWithin(radius, of: upComingStep)
            if !isCloseToCurrentStep && isCloseToUpComingStep {
                let userSnapToStepDistanceFromManeuver = distance(along: upComingStep.coordinates!, from: location.coordinate)
                let secondsToEndOfStep = userSnapToStepDistanceFromManeuver / location.speed
                incrementRouteProgress(secondsToEndOfStep <= RouteControllerMediumAlertInterval ? .medium : .low, location: location, updateStepIndex: true)
                return true
            }
        }
        
        return isCloseToCurrentStep
    }
    
    func incrementRouteProgress(_ newlyCalculatedAlertLevel: AlertLevel, location: CLLocation, updateStepIndex: Bool) {
        
        if updateStepIndex {
            routeProgress.currentLegProgress.stepIndex += 1
        }
        
        // If the step is not being updated, don't accept a lower alert level.
        // A lower alert level can only occur when the user begins the next step.
        guard newlyCalculatedAlertLevel.rawValue > routeProgress.currentLegProgress.alertUserLevel.rawValue || updateStepIndex else {
            return
        }
        
        if routeProgress.currentLegProgress.alertUserLevel != newlyCalculatedAlertLevel {
            routeProgress.currentLegProgress.alertUserLevel = newlyCalculatedAlertLevel
            // Use fresh user location distance to end of step
            // since the step could of changed
            let userDistance = distance(along: routeProgress.currentLegProgress.currentStep.coordinates!, from: location.coordinate)
            
            NotificationCenter.default.post(name: RouteControllerAlertLevelDidChange, object: self, userInfo: [
                RouteControllerAlertLevelDidChangeNotificationRouteProgressKey: routeProgress,
                RouteControllerAlertLevelDidChangeNotificationDistanceToEndOfManeuverKey: userDistance
                ])
        }
    }
    
    func reroute(from location: CLLocation) {
        if let lastRerouteLocation = lastRerouteLocation {
            guard location.distance(from: lastRerouteLocation) >= RouteControllerMaximumDistanceBeforeRecalculating else {
                return
            }
        }

        if isRerouting {
            return
        }
        
        isRerouting = true
        
        resetStartCounter()
        delegate?.routeController?(self, willRerouteFrom: location)
        NotificationCenter.default.post(name: RouteControllerWillReroute, object: self, userInfo: [
            MBRouteControllerNotificationLocationKey: location
            ])
        
        routeTask?.cancel()
        
        let options = routeProgress.route.routeOptions
        options.waypoints = [Waypoint(coordinate: location.coordinate)] + routeProgress.remainingWaypoints
        
        if let firstWaypoint = options.waypoints.first, location.course >= 0 {
            firstWaypoint.heading = location.course
            firstWaypoint.headingAccuracy = 90
        }
        
        self.lastRerouteLocation = location
        
        if let accessToken = routeProgress.route.accessToken, let apiEndpoint = routeProgress.route.apiEndpoint, let host = apiEndpoint.host {
            directions = Directions(accessToken: accessToken, host: host)
        }
        
        routeTask = directions.calculate(options, completionHandler: { [weak self] (waypoints, routes, error) in
            defer {
                self?.isRerouting = false
            }
            
            guard let strongSelf = self else {
                return
            }
            
            if let route = routes?.first {

                // If the first step of the new route is greater than 0.5km, let user continue without announcement.
                var alertLevel: AlertLevel = .none
                if let firstLeg = route.legs.first, let firstStep = firstLeg.steps.first, firstStep.distance > 500 {
                    alertLevel = .depart
                }
                strongSelf.routeProgress = RouteProgress(route: route, legIndex: 0, alertLevel: alertLevel)
                strongSelf.routeProgress.currentLegProgress.stepIndex = 0
                strongSelf.delegate?.routeController?(strongSelf, didRerouteAlong: route)
            } else if let error = error {
                strongSelf.delegate?.routeController?(strongSelf, didFailToRerouteWith: error)
                NotificationCenter.default.post(name: RouteControllerDidFailToReroute, object: self, userInfo: [
                    MBRouteControllerNotificationErrorKey: error
                    ])
            }
        })
    }
    
    func monitorStepProgress(_ location: CLLocation) {
        // Force an announcement when the user begins a route
        var alertLevel: AlertLevel = routeProgress.currentLegProgress.alertUserLevel == .none ? .depart : routeProgress.currentLegProgress.alertUserLevel
        var updateStepIndex = false
        let profileIdentifier = routeProgress.route.routeOptions.profileIdentifier
        
        let userSnapToStepDistanceFromManeuver = distance(along: routeProgress.currentLegProgress.currentStep.coordinates!, from: location.coordinate)
        let secondsToEndOfStep = userSnapToStepDistanceFromManeuver / location.speed
        var courseMatchesManeuverFinalHeading = false
        
        let minimumDistanceForHighAlert = RouteControllerMinimumDistanceForHighAlert(identifier: profileIdentifier)
        let minimumDistanceForMediumAlert = RouteControllerMinimumDistanceForMediumAlert(identifier: profileIdentifier)
        
        // Bearings need to normalized so when the `finalHeading` is 359 and the user heading is 1,
        // we count this as within the `RouteControllerMaximumAllowedDegreeOffsetForTurnCompletion`
        if let upcomingStep = routeProgress.currentLegProgress.upComingStep, let finalHeading = upcomingStep.finalHeading, let initialHeading = upcomingStep.initialHeading {
            let initialHeadingNormalized = wrap(initialHeading, min: 0, max: 360)
            let finalHeadingNormalized = wrap(finalHeading, min: 0, max: 360)
            let userHeadingNormalized = wrap(location.course, min: 0, max: 360)
            let expectedTurningAngle = differenceBetweenAngles(initialHeadingNormalized, finalHeadingNormalized)
            
            // If the upcoming maneuver is fairly straight,
            // do not check if the user is within x degrees of the exit heading.
            // For ramps, their current heading will very close to the exit heading.
            // We need to wait until their moving away from the maneuver location instead.
            // We can do this by looking at their snapped distance from the maneuver.
            // Once this distance is zero, they are at more moving away from the maneuver location
            if expectedTurningAngle <= RouteControllerMaximumAllowedDegreeOffsetForTurnCompletion {
                courseMatchesManeuverFinalHeading = userSnapToStepDistanceFromManeuver == 0
            } else {
                courseMatchesManeuverFinalHeading = differenceBetweenAngles(finalHeadingNormalized, userHeadingNormalized) <= RouteControllerMaximumAllowedDegreeOffsetForTurnCompletion
            }
        }

        // When departing, `userSnapToStepDistanceFromManeuver` is most often less than `RouteControllerManeuverZoneRadius`
        // since the user will most often be at the beginning of the route, in the maneuver zone
        if alertLevel == .depart && userSnapToStepDistanceFromManeuver <= RouteControllerManeuverZoneRadius {
            // If the user is close to the maneuver location,
            // don't give a depature instruction.
            // Instead, give a `.high` alert.
            if secondsToEndOfStep <= RouteControllerHighAlertInterval {
                alertLevel = .high
            }
        } else if userSnapToStepDistanceFromManeuver <= RouteControllerManeuverZoneRadius {
            // Use the currentStep if there is not a next step
            // This occurs when arriving
            let step = routeProgress.currentLegProgress.upComingStep?.maneuverLocation ?? routeProgress.currentLegProgress.currentStep.maneuverLocation
            let userAbsoluteDistance = step - location.coordinate
            
            // userAbsoluteDistanceToManeuverLocation is set to nil by default
            // If it's set to nil, we know the user has never entered the maneuver radius
            if routeProgress.currentLegProgress.currentStepProgress.userDistanceToManeuverLocation == nil {
                routeProgress.currentLegProgress.currentStepProgress.userDistanceToManeuverLocation = RouteControllerManeuverZoneRadius
            }
            
            let lastKnownUserAbsoluteDistance = routeProgress.currentLegProgress.currentStepProgress.userDistanceToManeuverLocation
            
            // The objective here is to make sure the user is moving away from the maneuver location
            // This helps on maneuvers where the difference between the exit and enter heading are similar
            if  userAbsoluteDistance <= lastKnownUserAbsoluteDistance! {
                routeProgress.currentLegProgress.currentStepProgress.userDistanceToManeuverLocation = userAbsoluteDistance
            }
            
            if routeProgress.currentLegProgress.upComingStep?.maneuverType == ManeuverType.arrive {
                alertLevel = .arrive
            } else if courseMatchesManeuverFinalHeading {
                updateStepIndex = true
                
                // Look at the following step to determine what the new alert level should be
                if let upComingStep = routeProgress.currentLegProgress.upComingStep {
                    alertLevel = upComingStep.expectedTravelTime <= RouteControllerMediumAlertInterval ? .medium : .low
                } else {
                    assert(false, "In this case, there should always be an upcoming step")
                }
            }
        } else if secondsToEndOfStep <= RouteControllerHighAlertInterval && routeProgress.currentLegProgress.currentStep.distance > minimumDistanceForHighAlert {
            alertLevel = .high
        } else if secondsToEndOfStep <= RouteControllerMediumAlertInterval &&
            // Don't alert if the route segment is shorter than X
            // However, if it's the beginning of the route
            // There needs to be an alert
            routeProgress.currentLegProgress.currentStep.distance > minimumDistanceForMediumAlert {
            alertLevel = .medium
        }
        
        incrementRouteProgress(alertLevel, location: location, updateStepIndex: updateStepIndex)
    }
}

struct SessionState {
    let identifier = UUID()
    var departureTimestamp: Date?
    var arrivalTimestamp: Date?
    
    var totalDistanceCompleted: CLLocationDistance = 0
    
    var numberOfReroutes = 0
    var lastRerouteDate: Date?
    
    var currentRoute: Route
    var currentRequestIdentifier: String?
    
    var originalRoute: Route
    var originalRequestIdentifier: String?
    
    var pastLocations = FixedLengthQueue<CLLocation>(length: 40)
    
    init(currentRoute: Route, originalRoute: Route) {
        self.currentRoute = currentRoute
        self.originalRoute = originalRoute
    }
}

// MARK: - Telemetry
extension RouteController {
    // MARK: Sending events
    func sendDepartEvent() {
        events.enqueueEvent(withName: MMEEventTypeNavigationDepart, attributes: events.navigationDepartEvent(routeController: self))
        events.flush()
    }

    func sendArriveEvent() {
        events.enqueueEvent(withName: MMEEventTypeNavigationArrive, attributes: events.navigationArriveEvent(routeController: self))
        events.flush()
    }
    
    func sendCancelEvent() {
        events.enqueueEvent(withName: MMEEventTypeNavigationCancel, attributes: events.navigationCancelEvent(routeController: self))
        events.flush()
    }
    
    func sendFeedbackEvent(event: CoreFeedbackEvent) {
        // remove from outstanding event queue
        if let index = outstandingFeedbackEvents.index(of: event) {
            outstandingFeedbackEvents.remove(at: index)
        }
        
        let eventName = event.eventDictionary["event"] as! String
        let eventDictionary = events.navigationFeedbackEventWithLocationsAdded(event: event.eventDictionary, eventTimestamp: event.timestamp, routeController: self)
        
        events.enqueueEvent(withName: eventName, attributes: eventDictionary)
        events.flush()
    }
    
    // MARK: Enqueue feedback
    
    func enqueueFeedbackEvent(type: FeedbackType, description: String?) {
        let eventDictionary = events.navigationFeedbackEvent(routeController: self, type: type, description: description)
        outstandingFeedbackEvents.append(FeedbackEvent(timestamp: Date(), eventDictionary: eventDictionary))
    }
    
    func enqueueRerouteEvent() {
        let timestamp = Date()
        
        let eventDictionary = events.navigationRerouteEvent(routeController: self)
        
        sessionState.lastRerouteDate = timestamp
        sessionState.numberOfReroutes += 1
        
        outstandingFeedbackEvents.append(RerouteEvent(timestamp: timestamp, eventDictionary: eventDictionary))
    }
    
    func checkAndSendOutstandingFeedbackEvents(forceAll: Bool) {
        let now = Date()
        let eventsToPush = forceAll ? outstandingFeedbackEvents : outstandingFeedbackEvents.filter {
            now.timeIntervalSince($0.timestamp) > SecondsBeforeCollectionAfterFeedbackEvent
        }
        for event in eventsToPush {
            sendFeedbackEvent(event: event)
        }
    }
    
    func resetSession() {
        sessionState = SessionState(currentRoute: routeProgress.route, originalRoute: routeProgress.route)
    }
}
