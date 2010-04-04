class ChallengeAssignment < ActiveRecord::Base
  # We use "-1" to represent all the requested items matching 
  ALL = -1

  belongs_to :collection
  belongs_to :offer_signup, :class_name => "ChallengeSignup"
  belongs_to :request_signup, :class_name => "ChallengeSignup"
  belongs_to :pinch_hitter, :class_name => "Pseud"
  belongs_to :pinch_request_signup, :class_name => "ChallengeSignup"

  named_scope :for_request_signup, lambda {|signup|
    {:conditions => ['request_signup_id = ?', signup.id]}
  }

  named_scope :for_offer_signup, lambda {|signup|
    {:conditions => ['offer_signup_id = ?', signup.id]}
  }

  named_scope :by_offering_user, lambda {|user|
    {
      :select => "DISTINCT challenge_assignments.*",
      :joins => "INNER JOIN challenge_signups ON challenge_assignments.offer_signup_id = challenge_signups.id
                 INNER JOIN pseuds ON challenge_signups.pseud_id = pseuds.id
                 INNER JOIN users ON pseuds.user_id = users.id",
      :conditions => ['users.id = ?', user.id]
    }
  }

  named_scope :by_requesting_user, lambda {|user|
    {
      :select => "DISTINCT challenge_assignments.*",
      :joins => "INNER JOIN challenge_signups ON challenge_assignments.request_signup_id = challenge_signups.id
                 INNER JOIN pseuds ON challenge_signups.pseud_id = pseuds.id
                 INNER JOIN users ON pseuds.user_id = users.id",
      :conditions => ['users.id = ?', user.id]
    }
  }

  named_scope :in_collection, lambda {|collection| {:conditions => ['collection_id = ?', collection.id] }}

  before_destroy :clear_assignment
  def clear_assignment
    if offer_signup
      offer_signup.assigned_as_offer = false
      offer_signup.save
    end

    if request_signup
      request_signup.assigned_as_request = false
      request_signup.save
    end
  end

  include Comparable
  def <=>(other)
    return 1 if self.request_signup.nil?
    return -1 if other.request_signup.nil?
    self.request_signup.pseud.name.downcase <=> other.request_signup.pseud.name.downcase
  end

  def pinch_hitter_byline
    pinch_hitter ? pinch_hitter.byline : ""
  end
  
  def pinch_hitter_byline=(byline)
    self.pinch_hitter = Pseud.by_byline(byline).first
  end

  def pinch_request_byline
    pinch_request_signup ? pinch_request_signup.pseud.byline : ""
  end

  def pinch_request_byline=(byline)
    pinch_pseud = Pseud.by_byline(byline).first
    self.pinch_request_signup = ChallengeSignup.in_collection(self.collection).by_pseud(pinch_pseud).first if pinch_pseud
  end

  # send assignments out to all participants 
  def self.send_out!(collection)
    collection.assignments.each do |assignment|
      assignment.sent_at = Time.now
      assigned_to = assignment.offer_signup ? assignment.offer_signup.pseud.user : (assignment.pinch_hitter ? assignment.pinch_hitter.user : nil)
      request = assignment.request_signup || assignment.pinch_request_signup
      UserMailer.deliver_challenge_assignment_notification(collection, assigned_to, assignment) if assigned_to && request
    end
  end

  # generate automatic match for a collection
  # this requires potential matches to already be generated
  def self.generate!(collection)
    ChallengeAssignment.clear!(collection)
    
    # we sort signups into buckets based on how many potential matches they have
    @request_match_buckets = {}
    @offer_match_buckets = {}
    @max_match_count = 0
    collection.signups.each do |signup|
      request_match_count = signup.request_potential_matches.count
      @request_match_buckets[request_match_count] ||= []
      @request_match_buckets[request_match_count] << signup
      @max_match_count = (request_match_count > @max_match_count ? request_match_count : @max_match_count)

      offer_match_count = signup.offer_potential_matches.count
      @offer_match_buckets[offer_match_count] ||= []
      @offer_match_buckets[offer_match_count] << signup
      @max_match_count = (offer_match_count > @max_match_count ? offer_match_count : @max_match_count)
    end

    # now that we have the buckets, we go through assigning people in order
    # of people with the fewest options first.
    # if someone has no potential matches they still get an assignment, just with no 
    # match.
    0.upto(@max_match_count) do |count|
      if @request_match_buckets[count]
        @request_match_buckets[count].sort_by {rand}.each do |request_signup|
          # go through the potential matches in order from best to worst and try and assign
          request_signup.reload
          next if request_signup.assigned_as_request
          ChallengeAssignment.assign_request!(collection, request_signup)
        end
      end
        
      if @offer_match_buckets[count]
        @offer_match_buckets[count].sort_by {rand}.each do |offer_signup|
          offer_signup.reload
          next if offer_signup.assigned_as_offer
          ChallengeAssignment.assign_offer!(collection, offer_signup)
        end
      end
    end
      
  end
  
  # go through the request's potential matches in order from best to worst and try and assign
  def self.assign_request!(collection, request_signup)
    assignment = ChallengeAssignment.new(:collection => collection, :request_signup => request_signup)
    request_signup.request_potential_matches.sort.reverse.each do |potential_match|
      # skip if this signup has already been assigned as an offer
      next if potential_match.offer_signup.assigned_as_offer

      # otherwise let's use it
      assignment.offer_signup = potential_match.offer_signup
      potential_match.offer_signup.assigned_as_offer = true
      potential_match.offer_signup.save!
      break
    end
    request_signup.assigned_as_request = true
    request_signup.save!

    assignment.save!
    assignment
  end

  # go through the offer's potential matches in order from best to worst and try and assign
  def self.assign_offer!(collection, offer_signup)
    assignment = ChallengeAssignment.new(:collection => collection, :offer_signup => offer_signup)
    offer_signup.offer_potential_matches.sort.reverse.each do |potential_match|
      # skip if already assigned as a request
      next if potential_match.request_signup.assigned_as_request
      
      # otherwise let's use it
      assignment.request_signup = potential_match.request_signup
      potential_match.request_signup.assigned_as_request = true
      potential_match.request_signup.save!
      break
    end
    offer_signup.assigned_as_offer = true
    offer_signup.save!
    assignment.save!
    assignment
  end

  # clear out all previous assignments
  def self.clear!(collection)
    ChallengeAssignment.destroy_all(["collection_id = ?", collection.id])
  end

  # create placeholders for any assignments left empty
  # (this is for after manual updates have left some users without an 
  # assignment)
  def self.update_placeholder_assignments!(collection)
    collection.signups.each do |signup|
      if signup.request_assignments.count > 1
        # get rid of empty placeholders no longer needed
        signup.request_assignments.each do |assignment|
          assignment.destroy if assignment.offer_signup.blank?
        end
      end
      if signup.request_assignments.empty?
        # not assigned to giver anymore! :(
        assignment = ChallengeAssignment.new(:collection => collection, :request_signup => signup)
        assignment.save
      end
      if signup.offer_assignments.count > 1
        signup.offer_assignments.each do |assignment|
          assignment.destroy if assignment.request_signup.blank?
        end
      end
      if signup.offer_assignments.empty?
        assignment = ChallengeAssignment.new(:collection => collection, :offer_signup => signup)
        assignment.save
      end
    end
  end

end
