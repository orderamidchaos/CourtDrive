package CourtDrive::Agent;

=head1 NAME
CourtDrive Web Agent Module

=head2 SYNOPSIS
C<< use CourtDrive::Agent qw(headers content_type content protocol domain report error has_error); >>
C<< my $webpage = CourtDrive::Agent->new($conf, $url) || print CourtDrive::Agent->error; >>
C<< my $output = ($webpage->has_error)? $webpage->error : do_stuff($webpage->content); >>

=head1 DESCRIPTION
This module facilitates the ability to scrape a website for content.

=head2 AUTHOR
Thomas Anderson
tanderson@orderamidchaos.com

=head2 COPYRIGHT
Copyright 2023
=cut

# load perl modules and import symbols into the namespace
use Modern::Perl;
use LWP::UserAgent;
use HTTP::Cookies;
use HTTP::Headers;
use HTTP::Request::Common;
use Benchmark;
use Data::Dumper;

# load CourtDrive perl modules and import symbols into the namespace
use CourtDrive::Debug 	qw(debug errlog is_array is_hash check_conf check_data);

# workaround for "day too big" bug in Time::Local
$Time::Local::Options{no_range_check} = 1;

# export public subroutine symbols
use Exporter 		qw(import);
our @EXPORT_OK = 	qw(headers content_type content protocol domain path report error has_error);

my $global_error = [];

sub new {
	my $this	= shift;
	my $class	= ref($this) || $this || "CourtDrive::Agent";

	my $conf	= check_conf(shift);
	my $url		= shift;
	my $params	= shift;
	my $debug	= shift;

	my $self = {
		conf		=> $conf,
		url 		=> $url || $conf->{urls}->[0] || "",						# URL to rip, passed in, or first auth URL, defined in conf file
		auth_urls	=> $conf->{urls} || [],										# authorized URLs to rip, defined in conf file
		agent_id	=> $conf->{browser}->{AGENT} || "CourtDrive Web Client",	# how the useragent is identified, defined in conf file
		max_size	=> $conf->{thresholds}->{RESPONSE_LIMIT} || 1048576,		# response size limit, bytes, defined in conf file
		timeout		=> $conf->{timeouts}->{REQUEST}/1000 || 12,					# request timeout limit, seconds, defined in conf file
		debug		=> $debug || 0,												# whether or not to emit debug output
		request_method	=> "POST",
		protocol	=> "",
		domain		=> "",
		path		=> "",
		file		=> "",
		extension	=> "",
		params		=> "",
		directory	=> [],
		input		=> "",
		cookies		=> {},
		headers		=> "",
		content		=> "",
		type		=> "",
		report		=> "\n",
		error		=> [] };

	bless $self, $class;
	$self->_init();
	return $self; }

sub _init {
	my $self = shift || return errlog({}, 500, "CourtDrive::Agent object not created.");

	# check if URL exists
	return $self->error(400, "No URL provided.") unless defined $self->{url};

	# determine URL components
	$self->{protocol}	= $1 if $self->{url} =~ s/^(https?:\/\/)(.*)/$2/;
	$self->{domain}		= $1 if $self->{url} =~ s/^((?:[^\/?]+?\/)+)(.*)/$2/;
	$self->{file}		= $1 if $self->{url} =~ s/^([^\/?]*?)(?:\?|$)(.*)/$2/;
	$self->{params}		= $1 if $self->{url} =~ s/^(.*)$//;

	# debug info
	$self->{report} .= "Agent... \n" 							if $self->{debug};
	$self->{report} .= "PROTOCOL: $self->{protocol} \n" 		if $self->{debug}>1 && $self->{protocol};
	$self->{report} .= "DOMAIN: $self->{domain} \n" 			if $self->{debug}>1 && $self->{domain};
	$self->{report} .= "FILE: $self->{file} \n" 				if $self->{debug}>1 && $self->{file};
	$self->{report} .= "PARAMS: $self->{params} \n" 			if $self->{debug}>1 && $self->{params};
	$self->{report} .= "\n"										if $self->{debug}>1;

	# check if the URL is permitted
	return $self->error(403, "Unauthorized url ".$self->{protocol}.$self->{domain}.".\nAuthorized URLS: ".Dumper(@{$self->{auth_urls}})) unless
		grep {/$self->{protocol}.$self->{domain}/} @{$self->{auth_urls}} or 			# authorized if $self->{domain} is in the list of $self->{auth_urls} or
		grep {$self->{protocol}.$self->{domain} =~ /\A\Q$_\E/} @{$self->{auth_urls}};	# if any of the $self->{auth_urls} is anchored to the beginning of $self->{domain}

	# break down filename into constituent parts
	if ($self->{file} =~ /(.*?)(\..*?)?$/) { $self->{file} = $1; $self->{extension} = $2 || ""; }
	if ($self->{file} =~ /http(?:s?):\/\//) { $self->{file} = ""; }

	# reconstruct url
	$self->{url} = $self->{protocol} . $self->{domain} . $self->{file} . $self->{extension};

	# break off directories from domain
	$self->{domain} =~ s/^(.*?)\/$/$1/;
	while ( $self->{domain} =~ s/^(.*?)\/([^\/]+?)$/$1/ ) { unshift @{$self->{directory}}, $2; }
	$self->{path} = "/" . join "/", @{$self->{directory}};

	# add query string parameters to the input
	$self->{input} .= $1 if $self->{params} =~ /^(.+)$/;

	# go get the content from the url
	$self->_fetch_page(); }

sub DESTROY { my $self = shift; }

sub _fetch_page {
	no warnings 'redefine';
	my $self = shift || return errlog({}, 500, "CourtDrive::Agent object not initialized.");
	my $start_time = new Benchmark;										# start timing the process
	@UserAgent::ISA = qw /LWP::UserAgent/; 								# subclass LWP::UserAgent to have the browser know about redirects
	sub UserAgent::redirect_ok {1;}										# redirect both GETS and POSTS
	my $ua = new UserAgent; 											# create new UserAgent object
	push @{ $ua->requests_redirectable }, 'POST';						# make POSTs redirectable

	$ua->agent($self->{agent});											# pass along the useragent info from the config

	$ua->parse_head(1);													# parse the http-equiv stuff
	$ua->env_proxy();													# detect proxy settings from ENV variables
	$ua->timeout($self->{timeout}); 									# set timeout # seconds
	$ua->default_header('Cache-Control' => "no-cache");					# prevent caching of our requests
	$ua->default_header('Accept-Ranges' => "none");						# prevent chunking

	# debug info
	$self->{report} .= "Creating request... \n" 						if $self->{debug};
	$self->{report} .= "URL: $self->{url} \n" 							if $self->{debug}>1 && $self->{url};
	$self->{report} .= "REQUEST_METHOD: $self->{request_method} \n" 	if $self->{debug}>1 && $self->{request_method};
	$self->{report} .= "CONTENT_TYPE: $self->{content_type} \n" 		if $self->{debug}>1 && $self->{content_type};
	$self->{report} .= "CONTENT_LENGTH: $self->{content_length} \n" 	if $self->{debug}>1 && $self->{content_length};
	$self->{report} .= "DEFAULT HEADER: $ua->{default_header} \n" 		if $self->{debug}>1 && $self->{default_header};
	$self->{report} .= "QUERY_STRING: $self->{query_string} \n" 		if $self->{debug}>1 && $self->{query_string};
	$self->{report} .= "INPUT: ".Dumper($self->{input})."\n" 			if $self->{debug}>1 and $self->{input};
	$self->{report} .= "\n"												if $self->{debug}>1;

	# create a new request object
	my $request;
	if (($self->{request_method} eq 'GET')||(!$self->{request_method})) {
		if (($self->{url} !~ /\?/) && $self->{input}) {$self->{url} .="?" . $self->{input};}
		if (($self->{url} !~ /\?/) && $self->{query_string}) { $self->{query_string} =~ s/(URL|NL|DEBUG)=.*?(?:&|$)//gis; $self->{url} .= "?" . $self->{query_string};}
		$request = new HTTP::Request GET => $self->{url}; }
	elsif ($self->{request_method} eq 'POST') {
		$request = POST $self->{url} , Content => $self->{input} unless defined $self->{upload};

		if (defined $self->{upload}) {
			$self->{input} =~ s/(?:^|&)(.*?)=(.*?)(?=&|$)/$1 => "$2", /gis; $self->{input} =~ s/^(.*?), $/$1/is;
			my $filename = ($self->{upload} =~ /^(?:.+?)\/([^\/]+?)$/)? $1 : $self->{upload};
			$request = eval(qq~POST "$self->{url}", Content_Type => 'form-data', Content => [ upload => ["$self->{upload}", "$filename"], $self->{input} ]~) if $self->{upload};
			$self->{report} .= qq~POST "$self->{url}", Content_Type => 'form-data', Content => [ upload => ["$self->{upload}", "$filename"], $self->{input}] if $self->{upload}\n\n~; }}
	else { return $self->error(405,"Unknown request method: " . $self->{request_method}); }

	if ($self->{conf}->{headers}) {										# set custom request headers
		foreach my $header (keys %{$self->{conf}->{headers}}) {
			$request->headers->header($header => $self->{conf}->{headers}->{$header}); }}

	# if we got an Authorization header, the client is back at it after being
	# prompted for a password so we insert the header as is in the request.
	if ($self->{authorization}) {$request->headers->header(Authorization => $self->{authorization});}

	my $setup_time = new Benchmark;						 				# time the request setup

	# debug info
	my $req_headers = $request->headers_as_string;
	$self->{report} .= "Sending request...\n" 							if $self->{debug};
	$self->{report} .= "INPUT: ".Dumper($self->{input})."\n" 			if $self->{debug}>1 and $self->{input};
	$self->{report} .= "REQUEST_HEADERS: ".Dumper($req_headers)."\n" 	if $self->{debug}>1 and $req_headers;
	$self->{report} .= "TIMEOUT: ".$self->{timeout}."\n" 				if $self->{debug}>1 and $self->{timeout};
	$self->{report} .= "\n"												if $self->{debug}>1;

	my $response = $ua->request($request);								# send request
	my $fetch_time = new Benchmark;										# time the fetch
	$self->{type} = $response->content_type || "text/html";				# get the content type returned

	if ($response->is_success) {										# check the response and read the output
		$self->{content} = $response->content;
		$self->{headers} = $response->headers_as_string; }
	else {
		if ($response->code == 401) { return $self->error(401, "Authenticate: ".$response->request->url.", ".$response->www_authenticate); }
		else {
			my $code = $response->code;
			my $message = $response->message;
			$self->error($code, $message); }}

	$self->{location} = $1 if $self->{headers} =~ /Location:(.*?)\n/i;	# get redirect

	my $res_red = scalar($response->is_redirect)? "yes":"no";

	$self->{report} .= "Received response ".($response->code? $response->code : "")." ".($response->message? $response->message : "")."...\n"	if $self->{debug};
	$self->{report} .= "URL: ".$response->request->url."\n"					if $self->{debug}>1 and $response->request->url;
	$self->{report} .= "SERVER: ".$response->server."\n"					if $self->{debug}>1 and $response->server;
	$self->{report} .= "REDIRECTED: $res_red\n"								if $self->{debug}>1 and $res_red;
	$self->{report} .= "LOCATION: ".$self->{location}."\n"					if $self->{debug}>1 and $self->{location};
	$self->{report} .= "CONTENT_TYPE: ".$self->{type}."\n"					if $self->{debug}>1 and $self->{type};
	$self->{report} .= "CONTENT_LENGTH: ".$response->content_length."\n"	if $self->{debug}>1 and $response->content_length;
	$self->{report} .= "RESPONSE_HEADERS: ".$self->{headers}."\n"			if $self->{debug}>1 and $self->{headers};
	$self->{report} .= "\n"													if $self->{debug}>1;

	my $td_setup = timediff($setup_time, $start_time);
	my $td_fetch = timediff($fetch_time, $setup_time);

	$self->{report} .= "Benchmarking:\n" .
	"  SETUP: " . $td_setup->[0] . " wall, " . int(1000*($td_setup->[1]+$td_setup->[2]+$td_setup->[3]+$td_setup->[4]+0.0005))/1000 . " cpu \t-- build the agent/request objects\n" .
	"  FETCH: " . $td_fetch->[0] . " wall, " . int(1000*($td_fetch->[1]+$td_fetch->[2]+$td_fetch->[3]+$td_fetch->[4]+0.0005))/1000 . " cpu \t-- make the request\n" .
	"" if $self->{debug}>1; }

sub headers {
	my $self = shift || return errlog({}, 500, "CourtDrive::Agent object not initialized.");
	return $self->{headers}; }

sub full_headers {
	my $self = shift || return errlog({}, 500, "CourtDrive::Agent object not initialized.");
	return $self->{headers} . "Content-type: " . $self->{type} . "\n\n"; }

sub content_type {
	my $self = shift || return errlog({}, 500, "CourtDrive::Agent object not initialized.");
	return ($self->{type})? $self->{type} : "text/html"; }

sub type_html {
	my $self = shift || return errlog({}, 500, "CourtDrive::Agent object not initialized.");
	return "Content-type:text/html\n\n"; }

sub content {
	my $self = shift || return errlog({}, 500, "CourtDrive::Agent object not initialized.");
	return $self->{content}; }

sub protocol {
	my $self = shift || return errlog({}, 500, "CourtDrive::Agent object not initialized.");
	return $self->{protocol}; }

sub domain {
	my $self = shift || return errlog({}, 500, "CourtDrive::Agent object not initialized.");
	return $self->{domain}; }

sub path {
	my $self = shift || return errlog({}, 500, "CourtDrive::Agent object not initialized.");
	return $self->{path}; }

sub report {
	my $self = shift || return errlog({}, 500, "CourtDrive::Agent object not initialized.");
	return $self->{report}; }

sub error {
	my $self = shift || undef;
	my $error_code = shift || 0;
	my $error_text = shift || "unknown";

	if (defined $self && ref $self) {
		if ($error_code || $error_text ne "unknown") {
			my $self_err_index = scalar @{$self->{error}};
			$self->{error}->[$self_err_index]->{code} = $error_code;
			$self->{error}->[$self_err_index]->{text} = $error_text;

			return undef; }
		else {
			my $self_err_str = (scalar @{$self->{error}})? "The $self->{request_method} request to $self->{url} failed.\n\n" : "";
			foreach my $sx (0..$#{$self->{error}}) {
				$self_err_str .= "Error Code: $self->{error}->[$sx]->{code}\n$self->{error}->[$sx]->{text}\n"; }
			$self_err_str .= qq~Please try again.  If this problem persists, please email the web administrator and include the exact text of the error.~ if scalar @{$self->{error}};

			return $self_err_str; }}
	else {
		if ($error_code || $error_text ne "unknown") {
			my $global_err_index = scalar @{$global_error};
			$global_error->[$global_err_index]->{code} = $error_code;
			$global_error->[$global_err_index]->{text} = $error_text;

			return undef; }
		else {
				my $global_err_str = (scalar @{$global_error})? "Your request could not be completed.\n\n" : "";
				foreach my $gx (0..$#{$global_error}) {
					$global_err_str .= "Error Code: $global_error->[$gx]->{code}$global_error->[$gx]->{text}\n"; }
				$global_err_str .= qq~Please try again.  If this problem persists, please email the web administrator and include the exact text of the error.~ if scalar @{$global_error};

				return $global_err_str; }}}

sub has_error {
	my $self = shift || return errlog({}, 500, "CourtDrive::Agent object not initialized.");
	return (scalar @{$self->{error}}) + (scalar @{$global_error}); }

sub _encode_url {
	my $self = shift || undef;
	my $str = shift || "";
	$str =~ s/([^0-9A-Za-z_-])/sprintf("%%%02lX",unpack('C',$1))/eg;
	return $str; }

sub _encode_html {
	my $self = shift || undef;
	my $str = shift || "";
	unless (defined $self && $self->{debug} > 1) {
		$str =~ s/([^0-9A-Za-z])/sprintf("&#%d;",ord($1))/eg;
		$str =~ s/&#10;/\n/gis; }
	return $str; }

sub _encode_str {
	my $self = shift || undef;
	my $str = shift || "";
	$str =~ s/(["'@\$\n\r\0\\])/\\$1/g;
	return $str; }

sub _decode_url {
	my $self = shift || undef;
	my $str = shift || "";
	$str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
	return $str; }

1;
