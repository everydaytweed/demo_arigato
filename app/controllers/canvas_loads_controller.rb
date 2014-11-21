class CanvasLoadsController < ApplicationController
  include ActionController::Live
  
  Mime::Type.register "text/event-stream", :stream

  before_action :set_canvas_load, only: [:show, :setup_course]

  def index
    @canvas_loads = current_user.canvas_loads
  end

  def show
  end

  def new
    @canvas_load = CanvasLoad.new(courses: sample_courses)
  end

  def create
    @canvas_load = current_user.canvas_loads.build(canvas_load_params)
    @canvas_load.canvas_domain = current_user.authentications.find_by_provider('canvas').provider_url
    if @canvas_load.save    
      render :create
    else
      render :new
    end
  end

  def setup_course

    subaccount_name = 'Canvas Demo Courses'
    response.headers['Content-Type'] = 'text/event-stream'
    sub_account_id = nil

    begin
      response.stream.write "Starting setup. This will take a few moments...\n\n"
      if @canvas_load.sis_id.present?
        response.stream.write "Checking sisID...\n\n"
        if @canvas_load.check_sis_id
          response.stream.write "Found valid user for teacher role.\n\n"
        else
          response.stream.write "Found no valid user for teacher role.\n\n" 
        end
      end

      if sub_account = @canvas_load.create_subaccount(subaccount_name)
        sub_account_id = sub_account['id']
        response.stream.write "Added subaccount: #{subaccount_name}.\n\n"
      else
        response.stream.write "You don't have permissions to add subaccount: #{subaccount_name}. Courses will be added to your default account.\n\n"
      end

      if @canvas_load.course_welcome
        response.stream.write "Checking for existing 'Welcome to Canvas' course.\n\n"
        if @canvas_load.setup_welcome
          response.stream.write "Preparing to create 'Welcome to Canvas' course.\n\n"
        else
          response.stream.write "Robot found a 'Welcome to Canvas' course -- won't create another.\n\n"
        end
      end

      response.stream.write "Adding Users -------------------------------\n\n"
      users = {}
      sample_users.each do |user|
        if users['user_id'] = @canvas_load.find_or_create_user(user)
          response.stream.write "Added user: #{user['first_name']} #{user['last_name']}.\n\n"
        else
          response.stream.write "You don't have permissions to add new users. No users will be added\n\n"
          break
        end
      end

      response.stream.write "Adding Courses -------------------------------\n\n"
      courses = {}
      @canvas_load.courses.each do |course|
        courses[course.id] = @canvas_load.find_or_create_course(course, sub_account_id)
        if courses[course.id][:existing]
          response.stream.write "#{course.name} already exists.\n\n"
        else
          response.stream.write "Added course: #{course.name}.\n\n"
        end
      end

      if users.present?
        response.stream.write "Adding Enrollments -------------------------------\n\n"
      end

    rescue IOError => ex # Raised when browser interrupts the connection
      response.stream.write "Error: #{ex}\n\n"
    rescue Canvas::ApiError => ex
      response.stream.write "Canvas Error: #{ex}\n\n"
    ensure
      response.stream.write "Finished!\n\n"
      response.stream.close # Prevents stream from being open forever
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_canvas_load
      @canvas_load = CanvasLoad.find(params[:id])
    end

    # Only allow a trusted parameter "white list" through.
    def canvas_load_params
      params.require(:canvas_load).permit(:lti_attendance, :lti_chat, :user_id, :sis_id, :suffix, :course_welcome, courses_attributes: [:is_selected, :content])
    end

    def sample_courses
      courses = google_drive.load_spreadsheet(Rails.application.secrets.courses_google_id, Rails.application.secrets.courses_google_gid)
      map_array(courses, []).map{|course| Course.new(content: course.to_json) }
    end

    def sample_users
      users = google_drive.load_spreadsheet(Rails.application.secrets.users_google_id, Rails.application.secrets.users_google_gid)
      # Convert csv results into user objects
      map_array(users, ['first_name', 'last_name'])
    end

    def map_array(data, reject_fields)
      header = data[0]
      results = data[1..data.length].map do |d| 
        header.each_with_index.inject({}) do |result, (key, index)| 
          result[key] = d[index] unless d[index].blank? || reject_fields.include?(key)
          result
        end
      end
      results = results.reject{|u| u['status'] != 'active'}
      results.each{|r| r.delete('status')}
      results
    end

end
