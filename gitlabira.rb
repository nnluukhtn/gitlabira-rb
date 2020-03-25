require 'sinatra/base'
require 'sinatra/custom_logger'
require 'logger'
require 'uri'
require 'net/http'
require 'net/https'
require 'json'

class Gitlabira < Sinatra::Base
  helpers Sinatra::CustomLogger

  PUSH_EVENT = :push_event
  MERGE_REQUEST_EVENT = :merge_request_event
  GITLAB_EVENT_MAPPING = {
    'Push Hook' => PUSH_EVENT,
    'Merge Request Hook' => MERGE_REQUEST_EVENT
  }
  MR_ACTION_REGEX = /(Resolves|Fixes|Closes) ([A-Z]+-\d+)/
  JIRA_BRANCH_REGEX = /[A-Z]+-\d+/
  GITLAB_REF_PREFIX = 'refs/heads/'

  configure :development, :production do
    logger = Logger.new(STDOUT)
    logger.level = Logger::DEBUG if development?
    set :logger, logger
    set :bind, '0.0.0.0'
  end

  def jira_authentication_header
    encoded_string = Base64.strict_encode64("#{ENV["JIRA_USER_NAME"]}:#{ENV["JIRA_PASSWORD"]}")
    "Basic #{encoded_string}"
  end

  def transit_jira_issue(jira_issue_id, transition_id, logger)
    uri = URI.parse("#{ENV["JIRA_PROJECT_ENDPOINT"]}/rest/api/2/issue/#{jira_issue_id}/transitions")
    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    req = Net::HTTP::Post.new(uri.path)
    req['Content-Type'] = 'application/json'
    req['Authorization'] = jira_authentication_header
    req.body = {
      'transition': { 'id': transition_id }
    }.to_json
    res = https.request(req)
    if res.kind_of? Net::HTTPSuccess
      logger.info ">>>>> Successfully transit issue: #{jira_issue_id} to transition: #{transition_id}"
    else
      logger.error ">>>>> Failed to transit issue: #{jira_issue_id} to transition: #{transition_id}"
      logger.error ">>>>> Reason: #{res.body}"
    end
  end

  def push_event_handler(params, logger)
    ref = params['ref']
    unless ref
      logger.info '>>>>> No ref parameter, ignoring'
      return
    end
    branch = ref.gsub(GITLAB_REF_PREFIX, '')
    results = branch.scan(JIRA_BRANCH_REGEX)
    if !results.empty?
      results.to_a.each do |ticket_code|
        transit_jira_issue(ticket_code, ENV['JIRA_START_DEVELOPMENT_TRANSITION'], logger)
      end
    else
      logger.info '>>>>> Branch is not followed regex, ignoring'
    end
  end

  def merge_request_event_handler(params, logger)
    object_attributes = params['object_attributes']
    unless object_attributes
      logger.info '>>>>> No object_attributes, ignoring'
      return
    end

    ticket_codes = []
    mr_results = object_attributes['description'].scan(MR_ACTION_REGEX)
    if !mr_results.empty?
      mr_results.each do |action, ticket_code|
        ticket_codes << ticket_code
      end
    end

    source_branch = object_attributes['source_branch']
    branch_results = source_branch.scan(JIRA_BRANCH_REGEX)
    if !branch_results.empty?
      branch_results.each do |item|
        ticket_codes << item
      end
    end

    if !ticket_codes.empty?
      mr_state = object_attributes['state']
      ticket_codes.each do |ticket_code|
        case mr_state
        when 'opened', 'updated'
          transit_jira_issue(ticket_code, ENV['JIRA_TO_REVIEW_TRANSITION'], logger)
        when 'closed'
          transit_jira_issue(ticket_code, ENV['JIRA_IN_DEVELOPMENT_TRANSITION'], logger)
        when 'merged'
          transit_jira_issue(ticket_code, ENV['JIRA_TO_QA_TRANSITION'], logger)
        end
      end
    else
      logger.info '>>>>> Branch and description are not followed regex, ignoring'
    end
  end

  get '/health' do
    'OK'
  end

  post '/hook' do
    body_params = JSON.parse(request.body.read)
    logger.info ">>>>> Request params: #{body_params.inspect}"
    gitlab_event = request.env['HTTP_X_GITLAB_EVENT']
    logger.info ">>>>> Gitlab event: #{gitlab_event || "NULL"}"

    case GITLAB_EVENT_MAPPING[gitlab_event]
    when PUSH_EVENT
      push_event_handler(body_params, logger)
    when MERGE_REQUEST_EVENT
      merge_request_event_handler(body_params, logger)
    end

    'OK'
  end
end
