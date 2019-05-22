import { createWidget } from "discourse/widgets/widget";
import { ajax } from "discourse/lib/ajax";
import RawHtml from "discourse/widgets/raw-html";
import { popupAjaxError } from "discourse/lib/ajax-error";

export default createWidget("vote-box", {
  tagName: "div.voting-wrapper",
  buildKey: () => "vote-box",

  buildClasses() {
    if (this.siteSettings.voting_show_who_voted) {
      return "show-pointer";
    }
  },

  defaultState() {
    return { allowClick: true, initialVote: false };
  },

  html(attrs, state) {
    var voteCount = this.attach("vote-count", attrs);
    var voteButton = this.attach("up-vote-button", attrs);
    var downVoteButton = this.siteSettings.voting_allow_down_vote ? this.attach("down-vote-button", attrs) : null;
    var voteOptions = this.attach("vote-options", attrs);
    let contents = [voteCount, voteButton, downVoteButton, voteOptions];

    if (state.votesAlert > 0) {
      const html =
        "<div class='voting-popup-menu vote-options popup-menu'>" +
        I18n.t("voting.votes_left", {
          count: state.votesAlert,
          path: this.currentUser.get("path") + "/activity/votes"
        }) +
        "</div>";
      contents.push(new RawHtml({ html }));
    }

    return contents;
  },

  hideVotesAlert() {
    if (this.state.votesAlert) {
      this.state.votesAlert = null;
      this.scheduleRerender();
    }
  },

  click() {
    this.hideVotesAlert();
  },

  clickOutside() {
    this.hideVotesAlert();
  },

  addUpVote() {
    return this.addVote(false);
  },

  addDownVote() {
    if (this.siteSettings.voting_allow_down_vote) {
      return this.addVote(true);
    }
  },

  addVote(downVote = false) {
    var topic = this.attrs;
    var state = this.state;
    const voteDirection = downVote?"down":"up";
    const voteReverseDirection = downVote?"up":"down";
    return ajax(`/voting/${voteDirection}_vote`, {
      type: "POST",
      data: {
        topic_id: topic.id
      }
    })
      .then(result => {
        topic.set("vote_count", result.vote_count);
        topic.set(`user_${voteDirection}_voted`, true);
        topic.set(`user_${voteReverseDirection}_voted`, false);
        topic.set(`user_voted`, true);
        this.currentUser.set("votes_exceeded", !result.can_vote);
        if (result.alert) {
          state.votesAlert = result.votes_left;
        }
        topic.set("who_voted", result.who_voted);
        state.allowClick = true;
        this.scheduleRerender();
      })
      .catch(popupAjaxError);
  },

  removeVote() {
    var topic = this.attrs;
    var state = this.state;
    return ajax("/voting/unvote", {
      type: "POST",
      data: {
        topic_id: topic.id
      }
    })
      .then(result => {
        topic.set("vote_count", result.vote_count);
        topic.set("user_voted", false);
        topic.set("user_up_voted", false);
        topic.set("user_down_voted", false);
        this.currentUser.set("votes_exceeded", !result.can_vote);
        topic.set("who_voted", result.who_voted);
        state.allowClick = true;
        this.scheduleRerender();
      })
      .catch(popupAjaxError);
  }
});
