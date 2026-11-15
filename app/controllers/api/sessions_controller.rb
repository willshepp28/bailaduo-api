module Api
  class SessionsController < DeviseTokenAuth::SessionsController
    def destroy
      if @resource
        # Reload token JSON under the same row lock used by token creation.
        # Keep the library's revocation, cleanup, and response behavior.
        @resource.with_lock { super }
      else
        super
      end
    end
  end
end
