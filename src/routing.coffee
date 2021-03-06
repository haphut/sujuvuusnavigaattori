## module state variables

speed_by_upper_limit = citynavi.config.colors.speed_by_upper_limit

transform_itinerary_to_linestring = window.citynavi.transform_itinerary_to_linestring

get_settings = window.citynavi.get_settings

## FIXME: Import these here when module dependencies are handled properly.
#draw_background_speeds = window.citynavi.draw_background_speeds
#draw_selected_itinerary = window.citynavi.draw_selected_itinerary

journey_id = null
route_timestamp = null

# map
map = null
map_under_drag = false # drag state

timeout = null

# Background map layers.
layers = {}

# map markers for current position, routing source, routing target, comment
positionMarker = sourceMarker = targetMarker = commentMarker = null
positionMarker2 = null

# map feature for accuracy of geolocated routing source
sourceCircle = null

# map layer for routing results
routeLayer = null

# latest geolocation event info
position_point = position_bounds = null

# vehicle position interpolation data
vehicles = []
previous_positions = []
interpolations = []


siri_to_live = (vehicle) ->
    vehicle:
        id: vehicle.MonitoredVehicleJourney.VehicleRef.value
    trip:
        route: vehicle.MonitoredVehicleJourney.LineRef.value
    position:
        latitude: vehicle.MonitoredVehicleJourney.VehicleLocation.Latitude
        longitude: vehicle.MonitoredVehicleJourney.VehicleLocation.Longitude
        bearing: vehicle.MonitoredVehicleJourney.Bearing


interpret_jore = (routeId) ->
    if citynavi.config.id != "helsinki"
        # no JORE codes in use, assume bus
        [mode, routeType, route] = ["BUS", 3, routeId]
    else if routeId?.match /^1019/
        [mode, routeType, route] = ["FERRY", 4, "Ferry"]
    else if routeId?.match /^1300/
        [mode, routeType, route] = ["SUBWAY", 1, routeId.substring(4,5)]
    else if routeId?.match /^300/
        [mode, routeType, route] = ["RAIL", 2, routeId.substring(4,5)]
    else if routeId?.match /^10(0|10)/
        [mode, routeType, route] = ["TRAM", 0, "#{parseInt routeId.substring(2,4)}"]
    else if routeId?.match /^(1|2|4).../
        [mode, routeType, route] = ["BUS", 3, "#{parseInt routeId.substring(1)}"]
    else
        # unknown, assume bus
        [mode, routeType, route] = ["BUS", 3, routeId]

    return [mode, routeType, route]

## Events before a page is shown

# set a class on the html root element based on the active page, for css use
$(document).bind "pageshow", (e, data) ->
    page_id = $.mobile.activePage.attr("id")
    # XXX toggle instead of set:
    $('html').attr('class', "ui-mobile mode-#{page_id}")

# This event is triggered when a page is about to be shown.
# There are also other pagebeforechange event handlers in other files.
# In this event handler map page related events are handled.
$(document).bind "pagebeforechange", (e, data) ->
    if typeof data.toPage != "string"
        console.log "pagebeforechange without toPage"
        return
    console.log "pagebeforechange", data.toPage
    u = $.mobile.path.parseUrl(data.toPage)

    if u.hash.indexOf('#navigation-page') == 0
        # determine bounds for initial map view
        start_bounds = L.latLngBounds([])
        # include the source marker
        if sourceMarker?
            start_bounds.extend sourceMarker.getLatLng()
        # include the current device position as well
        if position_bounds?
            start_bounds.extend position_bounds
        # XXX include at least the start of the first leg as well
        # if we got bounds data, zoom to that (no closer than level 18 though)
        if start_bounds.isValid()
            zoom = Math.min(map.getBoundsZoom(start_bounds), 18)
            map.setView(start_bounds.getCenter(), zoom)

    # The "#map-page?service" is used with the palvelukartta.coffee.
    if u.hash.indexOf('#map-page?service=') == 0
        srv_id = u.hash.replace(/.*\?service=/, "")
        e.preventDefault()
        route_to_service(srv_id)

    # If user has selected an address or service where to go to, then get the
    # place from the location_history (defined in autocomplete.coffee),
    # find a route to that place and show it on the map.
    if u.hash.indexOf('#map-page?destination=') == 0
        destination = u.hash.replace(/.*\?destination=/, "")
        e.preventDefault()
        # Destination in this case is the last index in the history.
        location = location_history.get(destination)
        route_to_destination(location)

# This event is triggered whenever the map page is shown and it
# resizes map view, opens proper source and target marker popups,
# fits map to route layer if any, and if there is no route layer then
# if we have the position where the user is then pans and zooms the map.
# This event happens after the pagebeforechange event.
$('#map-page').bind 'pageshow', (e, data) ->
    console.log "#map-page pageshow"

    resize_map()

    if targetMarker? # Check that typeof targetMarker !== "undefined" && targetMarker !== null
        if sourceMarker?
            sourceMarker.closePopup()
        targetMarker.closePopup()
        targetMarker.openPopup()
    else if sourceMarker?
        sourceMarker.closePopup()
        sourceMarker.openPopup()

    if routeLayer?
        mapfitBounds(routeLayer.getBounds())
    else if position_point?
        zoom = Math.min(map.getBoundsZoom(position_bounds), 15)
        map.setView(position_point, zoom)


$('#map-page').on 'pagebeforehide', (e, o) ->
    if o.nextPage.attr('id') is "front-page"
        reset_map()

reset_map = () ->
        if routeLayer?
            map.removeLayer routeLayer
            routeLayer = null
            citynavi.set_itinerary null

        $('.route-list ul').empty().hide().parent().removeClass("active")

        $('.control-details').empty()

        if sourceMarker?
            map.removeLayer sourceMarker
            sourceMarker = null
        if targetMarker?
            map.removeLayer targetMarker
            targetMarker = null
        if commentMarker?
            map.removeLayer commentMarker
            commentMarker = null

        if position_point
            zoom = Math.min(map.getBoundsZoom(position_bounds), 15)
            map.setView(position_point, zoom)
            set_source_marker(position_point, {accuracy: positionMarker.getRadius()})
        else
            map.setView(citynavi.config.center, citynavi.config.min_zoom)

        vehicles = []
        previous_positions = []
        interpolations = []


$('#live-page').bind 'pageshow', (e, data) ->
    map.setView(citynavi.config.center, citynavi.config.min_zoom)
    console.log "live map - subscribing to all vehicles"
    routeLayer = L.featureGroup().addTo(map)
    $.getJSON citynavi.config.siri_url, (data) ->
        for vehicle in data.Siri.ServiceDelivery.VehicleMonitoringDelivery[0].VehicleActivity
            handle_vehicle_update true, siri_to_live(vehicle)

        console.log "Got #{data.Siri.ServiceDelivery.VehicleMonitoringDelivery[0].VehicleActivity.length} vehicles in #{citynavi.config.name}"
        sub = citynavi.realtime?.client.subscribe "/location/#{citynavi.config.id}/**", (msg) ->
            handle_vehicle_update false, msg
        $('#live-page').on 'pagebeforehide', (e, o) ->
            if o.nextPage.attr('id') is "front-page" then sub.cancel()


$('#live-page').on 'pagebeforehide', (e, o) ->
    if o.nextPage.attr('id') is "front-page" then reset_map()

## Utilities

transport_colors = citynavi.config.colors.hsl
google_colors = citynavi.config.colors.google
google_icons = citynavi.config.icons.google

{
    hel_servicemap_unit_url,
    osm_notes_url,
    reittiopas_url
} = citynavi.config

format_code = (code) ->
    if code.substring(0,3) == "300" # local train
        return code.charAt(4)
    else if code.substring(0,4) == "1300" # metro
        return "Metro"
    else if code.substring(0,3) == "110" # helsinki night bus
        return code.substring(2,5)
    else if code.substring(0,4) == "1019" # suomenlinna ferry
        return "Suomenlinna ferry"
    return code.substring(1,5).replace(/^(0| )+| +$/, "")

format_time = (time) ->
    return time.replace(/(....)(..)(..)(..)(..)/,"$1-$2-$3 $4:$5")

# Route received from OTP is encoded so it needs to be decoded.
# translated from https://github.com/ahocevar/openlayers/blob/master/lib/OpenLayers/Format/EncodedPolyline.js
window.decode_otp_polyline = decode_polyline = (encoded, dims) ->
    # Start from origo
    point = (0 for i in [0...dims])

    # Loop over the encoded input string
    i = 0
    points = while i < encoded.length
        for dim in [0...dims]
            result = 0
            shift = 0
            loop
                b = encoded.charCodeAt(i++) - 63
                result |= (b & 0x1f) << shift
                shift += 5
                break unless b >= 0x20

            point[dim] += if result & 1 then ~(result >> 1) else result >> 1

        # Keep a copy in the result list
        point.slice(0)

    return points


## Markers

# Called when source marker should be added or it's position should be changed.
# (currently this happens if user clicks on the map to set it or
#  when user location changes and there is no source marker)
set_source_marker = (latlng, options) ->
    if sourceMarker?
        map.removeLayer(sourceMarker)
        sourceMarker = null
    sourceMarker = L.marker(latlng, {draggable: true}).addTo(map)
        .on('dragend', onSourceDragEnd)
    if options?.accuracy
        accuracy = options.accuracy
        measure = options.measure
        if not measure?
            measure = if accuracy < 2000 then "within #{Math.round(accuracy)} meters" else "within #{Math.round(accuracy/1000)} km"

        sourceMarker.bindPopup("The starting point for journey planner<br>(tap the red marker to update)<br>You are #{measure} from this point")

        if sourceCircle != null
            map.removeLayer(sourceCircle)
            sourceCircle = null
# don't display the gray source circle - confusing?
#            sourceCircle = L.circle(latlng, accuracy, {color: 'gray', opacity: 0.2, weight: 1}).addTo(map)
    else
        sourceMarker.bindPopup("The starting point for journey<br>(drag the marker to change)")

    if options?.popup?
        sourceMarker.openPopup()
    if options? 
        marker_changed(options)

# Called when target marker should be added or it's position should be changed.
# (currently this happens if user clicks on the map to set it or
#  user has selected an address or service where to go to on some other than map page)
set_target_marker = (latlng, options) ->
    if targetMarker?
        map.removeLayer(targetMarker)
        targetMarker = null
    targetMarker = L.marker(latlng, {draggable: true}).addTo(map)
        .on('dragend', onTargetDragEnd)
    description = options?.description
    if not description?
        description = "The end point for journey<br>(drag the marker to change)"
    targetMarker.bindPopup(description).openPopup()

    marker_changed(options)

onSourceDragEnd = (event) ->
    sourceMarker.unbindPopup()
    sourceMarker.bindPopup("The starting point for journey<br>(drag the marker to change)")
    marker_changed()

onTargetDragEnd = (event) ->
    targetMarker.unbindPopup()
    targetMarker.bindPopup("The end point for journey<br>(drag the marker to change)")
    marker_changed()

# When both markers have been placed, find the route between them
# and zoom out if necessary to fit the route on the screen.
marker_changed = (options) ->
    # FIXME: Add ways to change journey_id.
    journey_id = citynavi.get_journey_id()
    if sourceMarker? and targetMarker?
        find_route sourceMarker.getLatLng(), targetMarker.getLatLng(), (route) ->
            if options?.zoomToFit
                mapfitBounds(route.getBounds())
            else if options?.zoomToShow
                if not map.getBounds().contains(route.getBounds())
                    mapfitBounds(route.getBounds())


## Routing

poi_markers = []

# route_to_destination function is called when pagebeforechange event happens for
# the map page if user has selected an address or service where to go to
route_to_destination = (target_location) ->
    console.log "route_to_destination", target_location.name
    [lat, lng] = target_location.coords
    $.mobile.changePage("#map-page")
    target = new L.LatLng(lat, lng)
    set_target_marker(target, {description: target_location.name, zoomToFit: true})

    for marker in poi_markers
        map.removeLayer marker
    poi_markers = []
    # There is citynavi.poi_list if user has selected a service from the service list or
    # from the autocompletion list on the front page. Add their markers to the map.
    if citynavi.poi_list
        for poi in citynavi.poi_list
          do (poi) ->
            icon = L.AwesomeMarkers.icon
                svg: poi.category.get_icon_path()
                color: 'green'
            latlng = new L.LatLng(poi.coords[0], poi.coords[1])
            marker = L.marker(latlng, {icon: icon})
            marker.bindPopup "#{poi.name}"
            marker.poi = poi
            marker.on 'click', (e) ->
                set_target_marker(e.target.getLatLng(), {description: poi.name})
            marker.addTo map
            poi_markers.push marker
    console.log "route_to_destination done"

# Used with the palvelukartta.coffee
route_to_service = (srv_id) ->
    console.log "route_to_service", srv_id
    if not sourceMarker?
        alert("The device hasn't provided the current position!")
        return
    source = sourceMarker.getLatLng()
    params =
        service: srv_id
        distance: 1000
        lat: source.lat.toPrecision(7)
        lon: source.lng.toPrecision(7)
    $.getJSON hel_servicemap_unit_url + "?callback=?", params, (data) ->
        console.log "palvelukartta callback got data"
        window.service_dbg = data
        if data.length == 0
            alert("No service near the current position.")
            return
        $.mobile.changePage("#map-page")
        target = new L.LatLng(data[0].latitude, data[0].longitude)
        set_target_marker(target, {description: "#{data[0].name_en}<br>(closest #{srv_id})"})
        console.log "palvelukartta callback done"
    console.log "route_to_service done"

create_wait_leg = (start_time, duration, point, placename) ->
    leg =
        mode: "WAIT"
        routeType: null # non-transport
        route: ""
        duration: duration
        startTime: start_time
        endTime: start_time + duration
        legGeometry: {points: [point]}
        from:
            lat: point[0]*1e-5
            lon: point[1]*1e-5
            name: placename
    leg.to = leg.from
    return leg

offline_cleanup = (data) ->
    for itinerary in data.plan?.itineraries or []
        new_legs = []
        time = itinerary.startTime # tracks when next leg should start
        for leg, index in itinerary.legs
            # endTime not defined
            leg.endTime = leg.startTime+leg.duration
            # from and to not provided for walks
            if leg.mode == "WALK"
                leg.from =
                    lat: leg.legGeometry.points[0][0]*1e-5
                    lon: leg.legGeometry.points[0][1]*1e-5
                    name: legs?[index-1].to.name
                leg.to =
                    lat: _.last(leg.legGeometry.points)[0]*1e-5
                    lon: _.last(leg.legGeometry.points)[1]*1e-5
                    name: legs?[index+1].from.name

            # mode and routeType are hard-coded as bus
            # XXX how to do this for other areas?
            if citynavi.config.id == "helsinki"
                if leg.routeId?.match /^1019/
                    [leg.mode, leg.routeType] = ["FERRY", 4]
                    leg.route = "Ferry"
                else if leg.routeId?.match /^1300/
                    [leg.mode, leg.routeType] = ["SUBWAY", 1]
                    leg.route = "Metro"
                else if leg.routeId?.match /^300/
                    [leg.mode, leg.routeType] = ["RAIL", 2]
                else if leg.routeId?.match /^10(0|10)/
                    [leg.mode, leg.routeType] = ["TRAM", 0]
                else if leg.mode != "WALK"
                    [leg.mode, leg.routeType] = ["BUS", 3]

            if leg.startTime - time > 1000
                wait_time = leg.startTime-time
                time = leg.endTime
		# add the waiting time as a separate leg
                new_legs.push create_wait_leg leg.startTime - wait_time,
                    wait_time, leg.legGeometry.points[0], leg.from.name
            new_legs.push leg
            time = leg.endTime
        itinerary.legs = new_legs
    return data

find_route_offline = (source, target, callback) ->
    $.mobile.loading('show');
    window.citynavi.reach.find source, target, (itinerary) ->
        route_timestamp = new Date()
        $.mobile.loading('hide')

        if itinerary
            data = plan: itineraries: [itinerary]
        else
            data = plan: itineraries: []
        data = offline_cleanup data
        display_route_result data

        if (callback)
            callback(routeLayer)

        $.mobile.changePage "#map-page"

# clean up oddities in routing result data from OTP
otp_cleanup = (data) ->
    for itinerary in data.plan?.itineraries or []
        legs = itinerary.legs
        length = legs.length
        last = length-1

        # if there's time past walking in either end, add that to walking
        # XXX what if it's not walking?
        if not legs[0].routeType and legs[0].startTime != itinerary.startTime
            legs[0].startTime = itinerary.startTime
            legs[0].duration = legs[0].endTime - legs[0].startTime
        if not legs[last].routeType and legs[last].endTime != itinerary.endTime
            legs[last].endTime = itinerary.endTime
            legs[last].duration = legs[last].endTime - legs[last].startTime

        new_legs = []
        time = itinerary.startTime # tracks when next leg should start
        for leg in itinerary.legs
            # Route received from OTP is encoded so it needs to be decoded.
            leg.legGeometry.points = decode_polyline(leg.legGeometry.points, 2)

            # if there's unaccounted time before a walking leg
            if leg.startTime - time > 1000 and leg.routeType == null
                # move non-transport legs to occur before wait time
                wait_time = leg.startTime-time
                time = leg.endTime
                leg.startTime -= wait_time
                leg.endTime -= wait_time
                new_legs.push leg
                # add the waiting time as a separate leg
                new_legs.push create_wait_leg leg.endTime, wait_time,
                    _.last(leg.legGeometry.points), leg.to.name
            # else if there's unaccounted time before a leg
            else if leg.startTime - time > 1000
                wait_time = leg.startTime-time
                time = leg.endTime
		# add the waiting time as a separate leg
                new_legs.push create_wait_leg leg.startTime - wait_time,
                    wait_time, leg.legGeometry.points[0], leg.from.name
                new_legs.push leg
            else
                new_legs.push leg
                time = leg.endTime # next leg should start when this ended
        itinerary.legs = new_legs
    return data


# Called from marker_changed function when there are both source marker and target marker
# on the map and either of them has been set to a new place.
find_route = (source, target, callback) ->
    console.log "find_route", source.toString(), target.toString(), callback?
    if window.citynavi.reach?
        find_route_impl = find_route_offline
    else
        find_route_impl = find_route_otp
    find_route_impl source, target, callback
    console.log "find_route done"

find_route_otp = (source, target, callback) ->
    # See explanation of the parameters from
    # http://opentripplanner.org/apidoc/0.9.2/resource_Planner.html
    params =
        toPlace: "#{target.lat},#{target.lng}"
        fromPlace: "#{source.lat},#{source.lng}"
        minTransferTime: 180
        walkSpeed: 1.17
        maxWalkDistance: 100000
        numItineraries: 3
    if not $('[name=usetransit]').attr('checked')
        params.mode = $("input:checked[name=vehiclesettings]").val()
    else
        # always enable the following modes with transit
        # XXX we'd like to enable WALK, but TRANSIT,BICYCLE,WALK seems to mean
        # TRANSIT,WALK to OTP
        params.mode = "FERRY,"+$("input:checked[name=vehiclesettings]").val()
        $modes = $("#modesettings input:checked")
        if $modes.length == 0
            $modes = $("#modesettings input") # all disabled means all enabled
        for mode in $modes
            params.mode = $(mode).attr('name')+","+params.mode
    if $('#wheelchair').attr('checked')
        params.wheelchair = "true"
    if $('#prefer-free').attr('checked') and citynavi.config.id == "manchester"
        params.preferredRoutes = "GMN_1,GMN_2,GMN_3"
    # Call plan in the OpenTripPlanner RESTful API. See:
    # # http://opentripplanner.org/apidoc/0.9.2/resource_Planner.html
    $.getJSON citynavi.config.otp_base_url + "plan", params, (data) ->
        console.log "opentripplanner callback got data"
        route_timestamp = new Date()
        data = otp_cleanup(data)
        display_route_result(data)
            .then(() ->
                if callback
                    callback(routeLayer)
                $.mobile.changePage "#map-page"
                console.log "opentripplanner callback done"
            )

display_route_result = (data) ->
    if data.error?.msg
        $('#error-popup p').text(data.error.msg)
        $('#error-popup').popup()
        $('#error-popup').popup('open')
        return

    window.route_dbg = data

    if routeLayer != null
        map.removeLayer(routeLayer)
        routeLayer = null

    # Create empty layer group and add it to the map.
    routeLayer = L.featureGroup().addTo(map)

    maxDuration = _.max(i.duration for i in data.plan.itineraries)

    render_promises = []
    for index in [0, 1, 2]
        $list = $(".route-buttons-#{index}")
        $list.empty()
        $list.hide()
        $list.parent().removeClass("active")
        if index of data.plan.itineraries
            itinerary = data.plan.itineraries[index]
            # Render the route both on the map and on the footer.
            if index == 0
                #polylines = render_route_layer(itinerary, routeLayer)
                #$list.parent().addClass("active")
                #citynavi.set_itinerary itinerary

                # FIXME: This should not happen inside a display function but here goes.
                window.citynavi.start_following_itinerary(itinerary)

                render_promise = render_route_layer(itinerary, routeLayer)
                render_promises.push(render_promise)
                render_promise
                    .then((polylines) ->
                        $list.parent().addClass("active")
                        citynavi.set_itinerary(itinerary)
                        $list.css('width', itinerary.duration/maxDuration*100+"%")
                    )
            #else
            #    polylines = null
            #$list.css('width', itinerary.duration/maxDuration*100+"%")
            #render_route_buttons($list, itinerary, routeLayer, polylines, maxDuration)

    Promise.all(render_promises)
       .then(() -> resize_map()) # adjust map height to match space left by itineraries

query_average_speeds = (itinerary_id) ->
    connector = citynavi.get_connector()
    connector.getSpeedAveragesForItinerary(itinerary_id)

render_route_layer = (itinerary, routeLayer, callback) ->
    # FIXME: Until modules and module dependencies have been introduced, import
    # here.
    draw_background_speeds = window.citynavi.draw_background_speeds
    draw_selected_itinerary = window.citynavi.draw_selected_itinerary

    itinerary_linestring = transform_itinerary_to_linestring(itinerary)
    connector = citynavi.get_connector()

    average_speed_promise = new Promise((resolve, reject) -> resolve(true))
    if get_settings().recordandpublish
        average_speed_promise = connector
            .sendItinerary(journey_id, itinerary_linestring, route_timestamp)
            .then(query_average_speeds)
            .then(_.partial(draw_background_speeds, routeLayer))
            .catch(console.log)

    Promise.all([average_speed_promise])
        .then(() -> draw_selected_itinerary(routeLayer, itinerary_linestring))

handle_vehicle_update = (initial, msg) ->
                    id = msg.vehicle.id
                    pos = [msg.position.latitude, msg.position.longitude]
                    [mode, routeType, route] = interpret_jore(msg.trip.route)
                    if not (id of vehicles) # Data for a new vehicle was given from the server
                        # Draw icon for the vehicle
                        icon = L.divIcon({className: "navigator-div-icon", html: "<div id='vehicle-#{id}' style='background: #{google_colors[routeType ? mode]}'><span>#{route}</span><img src='static/images/#{google_icons[routeType ? mode]}' height='20px' /></div>"})
                        vehicles[id] = L.marker(pos, {icon: icon})
                            .addTo(routeLayer)
                        if not initial
                            console.log "new vehicle #{id} on route #{msg.trip.route}"
                    else
                        # Update the vehicle icon's place on the map.
                        # Use interpolation to make updates smoother.
                        old_pos = previous_positions[id]
                        steps = 30
                        interpolation = (index, id, old_pos) ->
                            lat = old_pos[0]+(pos[0]-old_pos[0])*(index/steps)
                            lng = old_pos[1]+(pos[1]-old_pos[1])*(index/steps)
                            vehicles[id].setLatLng([lat, lng])
                            if index < steps
                                interpolations[id] = setTimeout (-> interpolation index+1, id, old_pos), 1000
                            else
                                interpolations[id] = null
                        if previous_positions[id][0] != pos[0] or previous_positions[id][1] != pos[1]
                            if interpolations[id]
                                clearTimeout(interpolations[id])
                            interpolation 1, id, old_pos
                    previous_positions[id] = pos
                    $("#vehicle-#{id}").css('transform', "rotate(#{msg.position.bearing+90}deg)")
#                    $("#vehicle-#{id} img").css('transform', "rotate(-#{msg.position.bearing+90}deg)")
                    $("#vehicle-#{id} span").css('transform', "rotate(-#{msg.position.bearing+90}deg)")

# Renders the route buttons in the map page footer.
# Itienary is the  itienary suggested for the user to get from source to target.
# Route_layer is needed to resize the map when info is added to the footer here.
# polylines contains graphical representation of the itienary legs.
render_route_buttons = ($list, itinerary, route_layer, polylines, max_duration) ->
    trip_duration = itinerary.duration * 1000
    trip_start = itinerary.startTime

    length = itinerary.legs.length + 1 # Include space for the "Total" button.

    # The "Total" button.
    # even-width style:
#    $full_trip = $("<li class='leg'><div class='leg-bar' style='margin-right: 3px'><i style='font-weight: lighter'><img />Total</i><div class='leg-indicator'>#{Math.ceil(trip_duration/1000/60)}min</div></div></li>")
#    $full_trip.css("left", "{0}%")
#    $full_trip.css("width", "#{1/length*100}%")

    # fixed-width style:
    $full_trip = $("<li class='leg'><div class='leg-bar' style='margin-right: 3px'><i style='font-weight: lighter'><img />Total</i><div class='leg-indicator'>#{Math.ceil(trip_duration/1000/60)}min</div></div></li>")
    $full_trip.css("left", "{0}%")
    $full_trip.css("width", "{5}%")

    # Add event handler to zoom to show whole itienary on map if
    # there is no other click event defined for a button. The "Total" button is such.
    $full_trip.click (e) ->
        mapfitBounds(route_layer.getBounds())
        sourceMarker.closePopup()
        targetMarker.closePopup()
        sourceMarker.openPopup()
#    $list.append($full_trip)

    # label with itinerary start time
    $start = $("<li class='leg'><div class='leg-bar'><i><img src='static/images/walking.svg' height='100%' style='visibility: hidden' /></i><div class='leg-indicator' style='font-style: italic; text-align: left'>#{moment(trip_start).format("HH:mm")}</div></div></li>")
    $start.css("left", "#{0}%")
    $start.css("width", "#{15}%")
    $list.append($start)

    # label with itinerary end time
    $end = $("<li class='leg'><div class='leg-bar'><i><img src='static/images/walking.svg' height='100%' style='visibility: hidden' /></i><div class='leg-indicator' style='font-style: italic; text-align: right'>#{moment(trip_start+trip_duration).format("HH:mm")}</div></div></li>")
    $end.css("right", "#{0}%")
    $end.css("width", "#{15}%")
    $list.append($end)

    # Draw a button for each leg.
    for leg, index in itinerary.legs
      do (index) ->

        if leg.mode == "WALK" and $('#wheelchair').attr('checked')
            icon_name = "wheelchair.svg"
        else
            icon_name = google_icons[leg.routeType ? leg.mode]

        color = google_colors[leg.routeType ? leg.mode]

# GoodEnoughJourneyPlanner style:
        leg_start = (leg.startTime-trip_start)/trip_duration
        leg_duration = leg.duration*1000/trip_duration
        leg_label = "<img src='static/images/#{icon_name}' height='100%' />"

        # for long non-transit legs, display distance in place of route
        if not leg.routeType? and leg.distance? and leg.duration/max_duration > 0.35
            leg_subscript = "<div class='leg-indicator' style='font-weight: normal'>#{Math.ceil(leg.distance/100)/10}km</div>"
        else
            leg_subscript = "<div class='leg-indicator'>#{leg.route}</div>"

# YetAnotherJourneyPlanner style:
#        leg_start = (index+1)/length # leg_start and leg_duration are used for positioning the buttons.
#        leg_duration = 1/length
#        leg_label = "<img src='static/images/#{icon_name}' height='100%' /> #{leg.route}"
#        leg_subscript = "#{Math.ceil(leg.duration/1000/60)}min"

        $leg = $("<li class='leg'><div style='background: #{color};' class='leg-bar'><i>#{leg_label}</i>#{leg_subscript}</div></li>")

        $leg.css("left", "#{leg_start*100}%")
        $leg.css("width", "#{leg_duration*100}%")

        # Add event handler to zoom to leg in the map when user clicks the leg button in the footer.
        # The click event for the polylines have been defined in the render_route_layer function.
        $leg.click (e) ->
            if $list.parent().filter('.active').length > 0
                polylines[index].fire("click")
            else
                routeLayer.eachLayer (layer) ->
                    routeLayer.removeLayer(layer)
                $list.parent().siblings().removeClass('active')
                polylines = render_route_layer(itinerary, routeLayer)
                $list.parent().addClass('active')
                mapfitBounds(routeLayer.getBounds())
                citynavi.set_itinerary itinerary

        # if the i is a block, it needs a separate event handler
        $leg.find('i').click (e) ->
             polylines[index].fire("click")

        $list.append($leg) # Add button to the list that is shown to the user in the footer.

    $list.show()

# Not currently used.
find_route_reittiopas = (source, target, callback) ->
    params =
        request: "route"
        detail: "full"
        epsg_in: "wgs84"
        epsg_out: "wgs84"
        from: "#{source.lng},#{source.lat}"
        to: "#{target.lng},#{target.lat}"
    $.getJSON reittiopas_url, params, (data) ->
        window.route_dbg = data

        if routeLayer != null
            map.removeLayer(routeLayer)
            routeLayer = null
        else
            map.removeLayer(layers["osm"])
            map.addLayer(layers["cloudmade"])

        route = L.featureGroup().addTo(map)
        routeLayer = route

        legs = data[0][0].legs
        for leg in legs
          do () ->
            points = (new L.LatLng(point.y, point.x) for point in leg.shape)
            color = transport_colors[leg.type]
            polyline = new L.Polyline(points, {color: color})
                .on 'click', (e) ->
                    mapfitBounds(e.target.getBounds())
                    if marker?
                        marker.openPopup()
            polyline.addTo(route)
            if leg.type != 'walk'
                stop = leg.locs[0]
                last_stop = leg.locs[leg.locs.length-1]
                point = leg.shape[0]
                marker = L.marker(new L.LatLng(point.y, point.x)).addTo(route)
                    .bindPopup("<b><Time: #{format_time(stop.depTime)}</b><br /><b>From:</b> {stop.name}<br /><b>To:</b> #{last_stop.name}")

        if not map.getBounds().contains(route.getBounds())
            mapfitBounds(route.getBounds())


## Map initialisation

resize_map = () ->
    console.log "resize_map"
    height = window.innerHeight -
                                  # $('#map-page [data-role=header]').height() -
                                  $('#map-page [data-role=footer]').height() - # Footer contains buttons/textual info of the route
                                  # $('#route-buttons').height()
                                  0
    console.log "#map height", height

# commented out for always-fullscreen map underlay:
#    $('#map').height(height)
#    map.invalidateSize() # Leaflet.js function that updates the map.

    # calculate length of rotated attribution text based on map height
    attr_width = height - 10;
    $('.leaflet-control-attribution').css('width', attr_width+"px")
    attr_height = $('.leaflet-control-attribution').height()
    console.log ".leaflet-control-attribution height", attr_height
    $('.leaflet-control-attribution').css('left', attr_width/2-attr_height/8+"px")
    $('.leaflet-control-attribution').css('top', -attr_width/2-attr_height/2+"px")

$(window).on 'resize', () ->
    resize_map()

# Create a new Leaflet map and set it's center point to the
# location defined in the config.coffee
window.map_dbg = map = L.map('map', {minZoom: citynavi.config.min_zoom, zoomControl: false, attributionControl: false})
    .setView(citynavi.config.center, citynavi.config.min_zoom)


map.whenReady () ->
    console.log "map ready"
    setTimeout () -> map.fire 'zoomend', 0

# set a class on the map root element based on the current zoom, for css use
map.on 'zoomend', (e) ->
    console.log "zoomend"
    zoom = map.getZoom()
    minzooms = ("minzoom-"+i for i in [0..zoom]).join(" ")
    # XXX toggle instead of set:
    $('#map').attr('class', "leaflet-container leaflet-fade-anim "+minzooms)

$(document).on 'pageinit', ->
    if location.search? and location.search.length > 0
        console.log "location.search", location.search
        searchString = location.search.substring(1, location.search.length)
        searchParams = searchString.split("&")
        source = undefined
        target = undefined
        mode = undefined
        destname = undefined
        for param in searchParams
            if param == "usetransit=yes"
                #console.log "usetransit=yes"
                $('input[name=usetransit]').prop('checked', true)
                #$('#modesettings').find('input[name=BUS]').prop('checked', true)
                #$('#modesettings').find('input[name=TRAM]').prop('checked', true)
                #$('#modesettings').find('input[name=RAIL]').prop('checked', true)
                #$('#modesettings').find('input[name=SUBWAY]').prop('checked', true)
            else if param == "usetransit=no"
                #console.log "usetransit=no"
                $('input[name=usetransit]').prop('checked', false)
                #$('#modesettings').find('input[name=BUS]').prop('checked', false)
                #$('#modesettings').find('input[name=TRAM]').prop('checked', false)
                #$('#modesettings').find('input[name=RAIL]').prop('checked', false)
                #$('#modesettings').find('input[name=SUBWAY]').prop('checked', false)
            else if param.indexOf("mode=") == 0
                mode = param.substring(5, param.length)
                console.log "mode", mode
                $('input[name=vehiclesettings][value=' + mode + ']').prop('checked', true)
            else if param.indexOf("destname=") == 0
                destname = decodeURIComponent(param.substring(9, param.length))
            else if param.indexOf("start=") == 0
                start = param.substring(6, param.length)
                console.log "start", start
                if start.indexOf(',') != -1
                    parts = start.split(',')
                    lat = parts[0]
                    lng = parts[1]
                    source = new L.LatLng(parseFloat(lat), parseFloat(lng))                
            else if param.indexOf("destination=") == 0
                destination = param.substring(12, param.length)
                console.log "destination", destination
                if destination.indexOf(',') != -1
                    parts = destination.split(',')
                    lat = parts[0]
                    lng = parts[1]
                    target = new L.LatLng(parseFloat(lat), parseFloat(lng))
        #$('#wheelchair').prop('checked', false)
        #$('#prefer-free').prop('checked', false)
        #$('#use-speech').prop('checked', false)
        if source?
            set_source_marker(source)
        if target?
            if destname?
                set_target_marker(target, {description: destname})
            else
                set_target_marker(target)
    resize_map()
    map.invalidateSize()

DetailsControl = L.Control.extend
    options: {
        position: 'topleft'
    },

    onAdd: (map) ->
        $container = $("<div class='control-details'></div>")
        return $container.get(0)

new DetailsControl().addTo(map)
new DetailsControl({position: 'topright'}).addTo(map)

L.control.attribution({position: 'bottomright'}).addTo(map)

# Starts continuos watching of the user location using Leaflet.js locate function:
# http://leafletjs.com/reference.html#map-locate
# Don't use geolocation with Testem as it can't cancel the confirmation dialog
if not window.testem_mode
    map.locate
        setView: false
        maxZoom: 15
        watch: true
        timeout: 24*60*60*1000
        enableHighAccuracy: true

create_tile_layer = (map_config) ->
    L.tileLayer(map_config.url_template, map_config.opts)

for key, value of citynavi.config.maps
    layers[key] = create_tile_layer(value)

layers[citynavi.config.defaultmap].addTo(map)

# Use the leafletOsmNotes() function in file file "static/js/leaflet-osm-notes.js"
# to create layer for showing error notes from OSM in the map.
osmnotes = new leafletOsmNotes()

# Add the base maps and "error notes" layer to the layers control and add it to the map.
# See http://leafletjs.com/examples/layers-control.html for more info.
control_layers = {}
for key, value of citynavi.config.maps
    control_layers[value.name] = layers[key]

window.layers_control = L.control.layers(control_layers,
    "View map errors": osmnotes
).addTo(map)

# Add scale control to the map that shows current scale in
# metric (m/km) and imperial (mi/ft) systems
L.control.scale().addTo(map)

# Add button that allows user to navigate back in the page history
BackControl = L.Control.extend
    options: {
        position: 'topleft'
    },

    onAdd: (map) ->
        $container = $("<div id='back-control'>")
        $button = $("<a href='' data-role='button' data-rel='back' data-icon='arrow-l' data-mini='true'>Back</a>")
        $button.on 'click', (e) ->
            e.preventDefault()
            window.route_dbg = null
            if history.length < 2
                $.mobile.changePage("#front-page")
            else
                history.back()
            return false
        $container.append($button)
        return $container.get(0)

# new BackControl().addTo(map)

# Add zoom control to the map
L.control.zoom().addTo(map)

TRANSFORM_MAP = []

transform_location = (point) ->
    # If the point is close to known bad locations, transform them to right ones.
    for t in TRANSFORM_MAP
        src_pnt = new L.LatLng t.source.lat, t.source.lng
        current = new L.LatLng point.lat, point.lng
        radius = 100
        if src_pnt.distanceTo(current) < radius
            point.lat = t.dest.lat
            point.lng = t.dest.lng
            return

map.on 'dragstart', (e) ->
    map_under_drag = true
map.on 'dragend', (e) ->
    map_under_drag = false

map.on 'locationerror', (e) ->
    if e.message != "Geolocation error: The operation couldn’t be completed. (kCLErrorDomain error 0.)."
        alert(e.message)

# Triggered whenever user location has changed.
map.on 'locationfound', (e) ->
#    radius = e.accuracy / 2
    radius = e.accuracy
    measure = if e.accuracy < 2000 then "within #{Math.round(e.accuracy)} meters" else "within #{Math.round(e.accuracy/1000)} km"
    point = e.latlng
    transform_location point

    bbox_sw = citynavi.config.bbox_sw
    bbox_ne = citynavi.config.bbox_ne

    # Check if the location is sensible
    if not (bbox_sw[0] < point.lat < bbox_ne[0]) or not (bbox_sw[1] < point.lng < bbox_ne[1])
        if sourceMarker != null
            if positionMarker != null
               map.removeLayer(positionMarker) # red circle was stale
               map.removeLayer(positionMarker2)
               positionMarker = null
            return # no interest in updating to new location outside area
        # If there is no source marker then edit location to be on the center of the area
        console.log(bbox_sw[0], point.lat, bbox_ne[0])
        console.log(bbox_sw[1], point.lng, bbox_ne[1])
        console.log("using area center instead of geolocation outside area")
        point.lat = citynavi.config.center[0]
        point.lng = citynavi.config.center[1]
        e.accuracy = 2001 # don't draw red circle
        radius = 50 # draw small grey circle
        measure = "nowhere near"
        e.bounds = L.latLngBounds(bbox_sw, bbox_ne)

    # if position was visible, pan to keep it visible
    if positionMarker? && map.getBounds().contains(positionMarker.getLatLng())
        if not map.getBounds().contains(e.bounds)
            if not map_under_drag
                map.panTo(point)

    # save latest position info for later page change
    position_point = point
    position_bounds = e.bounds
    citynavi.set_source_location [point.lat, point.lng]

    # If there is already a position marker on map then remove it, and otherwise
    # if there is no source marker (indicating navigation start point) add it to map.
    if positionMarker != null
        map.removeLayer(positionMarker)
        map.removeLayer(positionMarker2)
        positionMarker = null
    else if sourceMarker == null
        zoom = Math.min(map.getBoundsZoom(e.bounds), 15)
        map.setView(point, zoom)
        # if the position is abnormally resolved outside front page, explain
        popup = $.mobile.activePage.attr("id") != "front-page"
        set_source_marker(point, {accuracy: radius, measure: measure, popup: popup})

    if e.accuracy > 2000
        return
    # Add the position marker to the map and set click event handler for it
    # to set source marker (indicating navigation start point).
    positionMarker = L.circle(point, radius, {color: 'red', weight: 1, opacity: 0.4}).addTo(map)
        .on 'click', (e) ->
            set_source_marker(point, {accuracy: radius, measure: measure})
    # If heading direction available draws the arrow marker
    # otherwise draws position center as a fixed-size circle
    # TODO: filter to avoid sudden switch between those two markers
    positionMarker2 = (
      if e.heading? and not isNaN e.heading
      then L.rotatedMarker point, angle: e.heading, icon: L.icon(iconUrl: 'static/images/arrow.svg', iconSize: [20, 20])
      else L.circleMarker(point, {radius: 7, color: 'red', weight: 2, fillOpacity: 1})
    ).addTo(map)
        .on 'click', (e) ->
            set_source_marker(point, {accuracy: radius, measure: measure})

set_source_or_target_marker = (e) ->
    # don't react to map clicks after both markers have been set
    if sourceMarker? and targetMarker?
        return

    # place the marker that's missing, giving priority to the source marker
    if sourceMarker == null
        set_source_marker(e.latlng, {popup: true})
    else if targetMarker == null
        set_target_marker(e.latlng)

map.on 'click', set_source_or_target_marker

# FIXME: Build a nicer interface sometime.
window.citynavi.set_source_or_target_marker = set_source_or_target_marker

# Create context menu that allows user to set source and target location as well as add error notes.
# The menu is shown when the user keeps finger long time on the touchscreen (see contextmenu event
# handler below).
contextmenu = L.popup().setContent('<a href="#" onclick="return setMapSource()">Set source</a> | <a href="#" onclick="return setMapTarget()">Set target</a> | <a href="#" onclick="return setNoteLocation()">Report map error</a>')

# Called when user clicks "Report map error" link in the context menu and adds the note.
set_comment_marker = (latlng) ->
    if commentMarker?
        map.removeLayer(commentMarker)
        commentMarker = null
    if not latlng?
        return
    commentMarker = L.marker(latlng, {draggable: true}).addTo(map)
    description = options?.description
    if not description?
        description = "Location for map error report"
    commentMarker.bindPopup(description).openPopup()


# This event happens on map page, when the user keeps finger long time on the touchscreen.
map.on 'contextmenu', (e) ->
    contextmenu.setLatLng(e.latlng)
    contextmenu.openOn(map) # Shows context menu defined above.

    # Functions that are called from the context menu's click event handlers are defined here.
    window.setMapSource = () ->
        set_source_marker(e.latlng)
        map.removeLayer(contextmenu)
        return false

    window.setMapTarget = () ->
        set_target_marker(e.latlng)
        map.removeLayer(contextmenu)
        return false

    window.setNoteLocation = () ->
        set_comment_marker(e.latlng)
        osmnotes.addTo(map)
        # Comment box with id "comment-box" has been defined in the index.html.
        $('#comment-box').show()
        hide = () ->
            $('#comment-box').hide()
            resize_map() # causes map redraw & notes update
            set_comment_marker()
        $('#comment-box .cancel-button').unbind 'click'
        $('#comment-box .cancel-button').bind 'click', ->
            hide()
            return false # event handled
        $('#comment-box').unbind 'submit'
        $('#comment-box').bind 'submit', ->
            text = $('#comment-box textarea').val()
            lat = commentMarker.getLatLng().lat
            lon = commentMarker.getLatLng().lng
            uri = osm_notes_url
            $.post uri, {lat: lat, lon: lon, text: text}, ()->
                $('#comment-box textarea').val("")
                hide()
            return false # don't submit form
        $.mobile.changePage '#map-page'
        resize_map()
        map.removeLayer(contextmenu)
        return false

mapfitBounds = (bounds) ->
    # map.fitBounds taking into account the map area that is covered by
    # the header, the footer or the trip details control
    topPadding = $(".ui-header").height() + $(".control-details").height()
    bottomPadding = $(".ui-footer").height()
    map.fitBounds bounds,
        paddingTopLeft: [0, topPadding]
        paddingBottomRight: [0, bottomPadding]

simulation_timestep_default = 10000

simulation_timeoutId = null
simulation_timestep = simulation_timestep_default

$('.journey-preview-link').on 'click', (e) ->
    itinerary = citynavi.get_itinerary()

    for route_id of citynavi.realtime?.subs or []
        citynavi.realtime.unsubscribe_route route_id
    for vehicle in vehicles
        routeLayer.removeLayer(vehicle)
    vehicles = []
    previous_positions = []
    interpolations = []

    console.log "Starting simulation"
    simulation_step(itinerary, itinerary.startTime - 60*1000)


lastLeg = null
currentStep = null
currentStepIndex = null
speak_queue = []

$('#navigation-page').on 'pagebeforehide', (e, o) ->
    if o.nextPage.attr('id') is "map-page"
        if simulation_timeoutId?
            clearTimeout simulation_timeoutId
            simulation_timeoutId = null
            citynavi.set_simulation_time null
        if positionMarker?
            map.removeLayer positionMarker
            map.removeLayer positionMarker2
            positionMarker = null
            position_point = null
            # XXX restore latest real geolocation
            citynavi.set_source_location null
        
        lastLeg = null
        currentStep = null
        currentStepIndex = null
        speak_queue = []


speak_real = (text) ->
    if citynavi.config.meSpeak? and $('#use-speech').attr('checked')
        console.log("*** Speaking", text)
        citynavi.config.meSpeak.speak(text, {}, speak_callback)
    else
        console.log("*** Not speaking", text)
        speak_callback() # done immediately as doing nothing

display_detail = (text) ->
    $('.control-details').html("<div class='route-details'><div>#{text}</div></div>")

speak = (text) ->
    if speak_queue.length == 0
        speak_queue.unshift(text)
        speak_real(text)
    else
        speak_queue.unshift(text)

speak_callback = () ->
    console.log "... speech done."
    speak_queue.pop()
    if speak_queue.length != 0
        text = speak_queue[0]
        speak_real(text)

dir_to_finnish =
    DEPART: ""
    NORTH: "Kulje pohjoiseen katua"
    SOUTH: "Kulje etelään katua"
    EAST: "Kulje itään katua"
    WEST: "Kulje länteen katua"
    NORTHWEST: "Kulje luoteeseen katua"
    SOUTHEAST: "Kulje kaakkoon katua"
    NORTHEAST: "Kulje koilliseen katua"
    SOUTHWEST: "Kulje lounaaseen katua"
    CONTINUE: "Jatka eteenpäin kadulle"
    LEFT: "Käänny vasemmalle kadulle"
    RIGHT: "Käänny oikealle kadulle"
    SLIGHTLY_LEFT: "Käänny viistosti vasemmalle kadulle"
    SLIGHTLY_RIGHT: "Käänny viistosti oikealle kadulle"
    HARD_LEFT: "Käänny jyrkästi vasemmalle kadulle"
    HARD_RIGHT: "Käänny jyrkästi oikealle kadulle"
    UTURN_LEFT: "Tee U-käännös vasemmalle kadulle"
    UTURN_RIGHT: "Tee U-käännös oikealle kadulle"
    CIRCLE_CLOCKWISE: "Kulje myötäpäivään liikenneympyrää"
    CIRCLE_COUNTERCLOCKWISE: "Kulje vastapäivään liikenneympyrää"
    ELEVATOR: "Mene hissillä kadulle"

path_to_finnish =
    "bike path": "pyörätie"
    path: "polku"
    "open area": "aukio"
    bridleway: "kärrypolku"

    platform: "laituri"

    footbridge: "ylikulkusilta"
    underpass: "alikulku"

    road: "tie"
    ramp: "liittymä"
    link: "linkki"
    "service road": "pihatie"
    alley: "kuja"
    "parking aisle": "parkkipaikka"
    byway: "sivutie"
    track: "ajoura"
    sidewalk: "jalkakäytävä"

    steps: "portaat"

    cycleway: "pyörätie"

    "Elevator": "hissi"

    "default level": "maantaso"

location_to_finnish = (location) ->
    corner = location.name.match(/corner of (.*) and (.*)/)

    if corner?
        return "katujen #{corner[1]} ja #{corner[2]} kulma"

    return path_to_finnish[location.name] or location.name or 'nimetön'

step_to_finnish_speech = (step) ->
    if step.relativeDirection and step.relativeDirection != "DEPART"
       text = dir_to_finnish[step.relativeDirection] or step.relativeDirection
    else
       text = dir_to_finnish[step.absoluteDirection] or step.asboluteDirection

    text += " " + (path_to_finnish[step.streetName] or step.streetName or 'nimetön')

    return text

display_step = (step) ->
    icon = L.divIcon({className: "navigator-div-icon"})

    marker = L.marker(new L.LatLng(step.lat, step.lon), {icon: icon}).addTo(routeLayer).bindLabel("#{((step.relativeDirection and step.relativeDirection != "DEPART") or step.absoluteDirection).toLowerCase().replace('_', ' ')} on #{step.streetName or 'unnamed path'}", {noHide: true}).showLabel()


simulation_step = (itinerary, time) ->
    simulation_timeoutId = setTimeout (-> simulation_step itinerary, time+simulation_timestep), 1000
    # XXX how to switch itinerary?

    citynavi.set_simulation_time moment(time)

    leg = null

    for l in itinerary.legs
        if l.startTime <= time < l.endTime # this leg is in progress
            leg = l

    if time < itinerary.legs[0].startTime
        leg =
            startTime: itinerary.startTime
            endTime: itinerary.legs[0].startTime
            legGeometry:
                points:
                    [[sourceMarker.getLatLng().lat*1e5, sourceMarker.getLatLng().lng*1e5]]
    else if time >= itinerary.legs[itinerary.legs.length-1].endTime
        leg =
            startTime: itinerary.legs[itinerary.legs.length-1].endTime
            endTime: itinerary.endTime
            legGeometry:
                points:
                    [[targetMarker.getLatLng().lat*1e5, targetMarker.getLatLng().lng*1e5]]

    if not leg?
        console.log "No current leg"
        return

    if not lastLeg?
        display_detail "Instructions start at "+itinerary.legs[0].from.name+"."
        speak "Ohjeet alkavat kadulta "+ location_to_finnish(itinerary.legs[0].from)
        if itinerary.legs[0].steps?[0]
            currentStep = itinerary.legs[0].steps?[0]
            currentStepIndex = 0
            display_step(currentStep)
            console.log "current step", currentStep

    if leg != lastLeg and leg?.steps?[0]
        currentStep = leg.steps[0]
        currentStepIndex = 0

    lastLeg = leg
    legIndex = itinerary.legs.indexOf(leg)+1

    geometry = ([p[0]*1e-5, p[1]*1e-5] for p in leg.legGeometry.points)

    share = (time-leg.startTime) / (leg.endTime-leg.startTime)

    if geometry.length > 1 and share != 0
        {latLng, predecessor} = L.GeometryUtil.interpolateOnLine(map, geometry, share)
    else
        [latLng, predecessor] = [L.latLng(geometry[0]), -1]

#    console.log leg, leg.startTime-itinerary.startTime, time-itinerary.startTime, leg.endTime-itinerary.startTime, {points: geometry}, share, "->", latLng.toString(), predecessor

    if currentStep? && latLng.distanceTo(new L.LatLng(currentStep.lat, currentStep.lon)) < 5
        step = currentStep
        display_detail "Next, go #{((step.relativeDirection and step.relativeDirection != "DEPART") or step.absoluteDirection).toLowerCase().replace('_', ' ')} on #{step.streetName or 'unnamed path'}."
        speak step_to_finnish_speech(step)
        currentStepIndex = currentStepIndex + 1
        currentStep = leg.steps?[currentStepIndex]

        if not currentStep?
            nextLeg = itinerary.legs?[legIndex+1]
            console.log "nextLeg", nextLeg
            if nextLeg?.steps?[0]
                currentStep = nextLeg?.steps?[0]
                currentStepIndex = 0
            else
                currentStep = null

        if currentStep?
            display_step currentStep
        else
            display_detail "Arriving at destination."
            speak "Saavutaan perille"

    accuracy = 50

    map.fire 'locationfound', construct_locationfound_event(latLng, accuracy)


construct_locationfound_event = (latLng, accuracy) ->
    lat = latLng.lat
    lng = latLng.lng

    latAccuracy = 180 * accuracy / 40075017
    lngAccuracy = latAccuracy / Math.cos(L.LatLng.DEG_TO_RAD * lat)
    bounds = L.latLngBounds(
        [lat - latAccuracy, lng - lngAccuracy],
        [lat + latAccuracy, lng + lngAccuracy])
    return {
        accuracy: accuracy
        latlng: L.latLng(lat, lng)
        bounds: bounds
    }
