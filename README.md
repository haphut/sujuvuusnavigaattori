# Sujuvuusnavigaattori

A bit like a car navigator but for cycling and for finding the best cycling routes in realtime, based on Open Data.

Sujuvuusnavigaattori helps one to find the best cycling routes, for example from home to work place. To do this it records location data from mobile phone client application to server when one is cycling. The cycler as well as other cyclers can then see fluency visualization that is formed from the cyclers' recorded data in realtime. The cycler can also see her/his own recorded routes later. The client application includes navigator and is heavily based on City Navigator proto https://github.com/HSLdevcom/navigator-proto by HSLdevcom.

To see the Sujuvuusnavigaattori running visit: http://sujuvuusnavigaattori.okf.fi/
There is also more general info in Finnish available at [Sujuvuuspilotti](http://fi.okfn.org/projects/sujuvuuspilotti/) page.

Main use cases:

1. While navigating cycler records cycled route with speed data and shares it, so that cyclers can use the data to plan cycling routes.
2. Cycler wants to share fluency data on streets from the navigator in realtime, so that cyclers can use the data for route planning right a way.

The project is directly connected to three other projects:
* https://github.com/okffi/sujuvuusnavigaattori-server
* https://github.com/okffi/sujuvuusnavigaattori-wrapper
* https://github.com/okffi/sujuvuusnavigaattori-otp

Open Data used:
<ul>
<li>OpenStreetMap
<li>Public transport timetables by
    <ul>
    <li><a href="http://www.oulunjoukkoliikenne.fi/english">Oulunliikenne</a>
    <li><a href="https://www.hsl.fi/en">Helsinki Region Transport</a>
    <li><a href="http://joukkoliikenne.tampere.fi/en/">Tampereen Joukkoliikenne</a> via <a href="http://www.hermiagroup.fi/its-factory/">ITS Factory</a>
    </ul>
<li>Geocoding / street address data via <a href="https://github.com/rekola/okffi-geocoder">OKF.fi Geocoder API</a> utilizing
    <ul>
    <li><a href="http://www.maanmittauslaitos.fi/en/opendata">The National Land Survey (NLS) topographic data</a>
    <li><a href="http://www.itella.fi/english/servicesandproducts/postalcodeservices/basicaddressfile.html">Itella basic address file</a>
    </ul>
</ul>

Technologies used: HTML5, Geolocation, Local storage

Libraries used: jQuery Mobile, Leaflet, Backbone.js, Moment.js


## Getting started ##

Node.js with NPM 1.2 or newer is required to build the project. For
Ubuntu 14.04 LTS, this can be acquired with
`sudo add-apt-repository ppa:chris-lea/node.js` followed by `sudo apt-get install nodejs`.

After installing Node.js go to the directory where you want to install the City Navigator.
There, run `git clone https://github.com/okffi/sujuvuusnavigaattori.git`. 

In the navigator-proto directory install dependencies with `npm install`.

Install build tool with `sudo npm install -g grunt-cli`. Run
`grunt server` and if everything goes well open
http://localhost:9001/ with your web browser.

Or, install build tool with `npm install grunt-cli` and run dev server with
`node_modules/.bin/grunt server`.

## Github use best practice for Sujuvuusnavigaattori project

1. Fork the repo 
2. Create a new feature branch for your work 
3. Submit an empty pull request from your branch to the main repo to show you have work in progress. Start the name of the pull request with "WIP: " 
4. Push your commits to your branch as you work
5. With last push, remove "WIP"-comment, and give unit test result instead.

Detail info at https://help.github.com/articles/fork-a-repo/

## Database schema ##

See [Sujuvuusnavigaattori server](https://github.com/okffi/sujuvuusnavigaattori-server).

