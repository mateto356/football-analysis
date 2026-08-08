WITH Results AS(
-- Base match results
-- Parameters: Country.name

SELECT
	Country.name AS country,
	season,
	date(date) AS date,
	stage,
	Match.id,
	ht.team_long_name AS home_team_name,
	at.team_long_name AS away_team_name,
	home_team_goal,
	away_team_goal,
	CASE
		WHEN home_team_goal > away_team_goal THEN ht.team_long_name || ' won'
		WHEN away_team_goal > home_team_goal THEN at.team_long_name || ' won'
		ELSE 'Draw' END AS result
FROM Match
JOIN Country
	ON Match.country_id = Country.id			-- extract country name
JOIN Team ht
	ON Match.home_team_api_id = ht.team_api_id	-- extract home team name
JOIN Team at
	ON Match.away_team_api_id = at.team_api_id	-- extract away team name
WHERE Country.name = 'Spain'					-- choose country
),
Points AS(
-- Points CTE
-- Expands each match into two rows, one per team
-- Calculates points, goals scored/conceded
-- and goal difference per team per match
-- UNION ALL used intentionally to preserve
-- duplicate point totals across teams

	SELECT
	season,
	stage,
	home_team_name AS team_name,
	CASE	-- Points: 3 for win, 1 for draw, 0 for loss
		WHEN home_team_goal > away_team_goal THEN 3
		WHEN away_team_goal > home_team_goal THEN 0
		ELSE 1 END AS points,
	home_team_goal AS goal_scored,
	away_team_goal AS goal_conceded,
	home_team_goal - away_team_goal AS goal_difference
FROM Results
UNION ALL	-- Away team perspective — mirrors home team logic above
SELECT
	season,
	stage,
	away_team_name AS team_name,
	CASE	-- Points: 3 for win, 1 for draw, 0 for loss
		WHEN away_team_goal > home_team_goal THEN 3
		WHEN home_team_goal > away_team_goal THEN 0
		ELSE 1 END AS points,
	away_team_goal AS goal_scored,
	home_team_goal AS goal_conceded,
	away_team_goal - home_team_goal AS goal_difference
FROM Results
),
League_table AS(
-- Cumulative league table per team per stage
-- Accumulates points, goals and goal difference
-- across all stages within each season
-- PARTITION BY season ensures stats reset each season
-- ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
-- ensures running total, not window average

SELECT
	season,
	stage,
	team_name,
	SUM(points) OVER(
					PARTITION BY season, team_name
					ORDER BY stage
					ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS total_points,
	SUM(goal_scored) OVER(
						PARTITION BY season, team_name
						ORDER BY stage
						ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS total_goals_scored,
	SUM(goal_conceded) OVER(
							PARTITION BY season, team_name
							ORDER BY stage
							ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS total_goals_conceded,
	SUM(goal_difference) OVER(
							PARTITION BY season, team_name
							ORDER BY stage
							ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS total_goals_difference
FROM Points
ORDER BY season, stage, total_points DESC
),
Team_rank AS(
-- Ranks teams within each stage per season
-- ROW_NUMBER used over RANK to avoid tied positions
-- Tiebreaker: goal difference (standard league rule)

SELECT 
	season,
	stage,
	ROW_NUMBER() OVER(
					PARTITION BY season, stage
					ORDER BY total_points DESC, total_goals_difference DESC) AS position,
	team_name,
	total_points,
	total_goals_scored,
	total_goals_conceded,
	total_goals_difference
FROM League_table
),
Rank_before AS(
-- Adds previous stage position for each team
-- Used to determine opponent ranking BEFORE facing the chosen team
-- LAG() looks back one stage within each season per team
-- COALESCE handles stage 1 where no previous position exists
-- by falling back to current stage position
-- PARTITION BY season prevents LAG crossing season boundaries

SELECT
	season,
	stage,
	team_name,
	position,
	COALESCE(LAG(position) OVER(PARTITION BY season, team_name ORDER BY stage), position) AS position_before
FROM Team_rank
ORDER BY season, stage, position
)

-- ============================================
-- Query 1: Results by opponent group
-- Win, draw, loss rates per manager era
-- ============================================
SELECT 
	manager,
	CASE
		WHEN position_before <= 5 THEN '1. 1st - 5th'
		WHEN position_before <= 10 THEN '2. 6th - 10th'
		WHEN position_before <= 15 THEN '3. 11th - 15th'
		ELSE '4. 16th - 20th' END AS group_before,
	COUNT(*) AS total_games,
	COUNT(CASE WHEN result LIKE 'Real Madrid CF%' THEN 1 END) AS wins,
	ROUND(COUNT(CASE WHEN result LIKE 'Real Madrid CF%' THEN 1 END)*100.0/COUNT(*), 1) AS wins_perc,
	COUNT(CASE WHEN result = 'Draw' THEN 1 END) AS draws,
	ROUND(COUNT(CASE WHEN result = 'Draw' THEN 1 END)*100.0/COUNT(*), 1) AS draws_perc,
	COUNT(CASE WHEN result NOT LIKE 'Real Madrid CF%' AND result != 'Draw' THEN 1 END) AS losses,
	ROUND(COUNT(CASE WHEN result NOT LIKE 'Real Madrid CF%' AND result != 'Draw' THEN 1 END)*100.0/COUNT(*), 1) AS losses_perc
FROM (SELECT
	CASE WHEN r.season IN ('2010/2011', '2011/2012', '2012/2013') THEN 'Mourinho' ELSE 'Others' END AS manager,
	r.season,
	r.stage,
	CASE WHEN r.home_team_name = 'Real Madrid CF' THEN r.away_team_name
		WHEN r.away_team_name = 'Real Madrid CF' THEN r.home_team_name END AS opponent,
	rb.position_before,
	r.result
FROM Results r
JOIN Rank_before rb
	ON r.season = rb.season AND r.stage = rb.stage AND opponent = rb.team_name
WHERE r.home_team_name = 'Real Madrid CF' OR r.away_team_name = 'Real Madrid CF'
ORDER BY r.season, r.stage)
GROUP BY manager, group_before

-- ============================================
-- Query 2: Goals by opponent group  
-- Average goals scored and conceded per manager era
-- ============================================

SELECT 
	manager,
	CASE
		WHEN position_before <= 5 THEN '1. 1st - 5th'
		WHEN position_before <= 10 THEN '2. 6th - 10th'
		WHEN position_before <= 15 THEN '3. 11th - 15th'
		ELSE '4. 16th - 20th' END AS group_before,
	SUM(goals_scored) AS total_goals_scored,
	SUM(goals_conceded) AS total_goals_conceded,
	SUM(goals_scored) - SUM(goals_conceded) AS goals_difference,
	ROUND(SUM(goals_scored) * 1.0 / COUNT(*), 2) AS avg_goals_scored,
	ROUND(SUM(goals_conceded) * 1.0 / COUNT(*), 2) AS avg_goals_conceded,
	ROUND((SUM(goals_scored) - SUM(goals_conceded)) * 1.0 / COUNT(*), 2) AS avg_goals_difference
FROM (SELECT
	CASE WHEN r.season IN ('2010/2011', '2011/2012', '2012/2013') THEN 'Mourinho' ELSE 'Others' END AS manager,
	r.season,
	r.stage,
	CASE 
		WHEN r.home_team_name = 'Real Madrid CF' THEN r.away_team_name
		WHEN r.away_team_name = 'Real Madrid CF' THEN r.home_team_name END AS opponent,
	rb.position_before,
	CASE 
		WHEN r.home_team_name = 'Real Madrid CF' THEN r.home_team_goal 
		ELSE r.away_team_goal END AS goals_scored,
	CASE
		WHEN r.home_team_name = 'Real Madrid CF' THEN r.away_team_goal 
		ELSE r.home_team_goal END AS goals_conceded,
	r.result
FROM Results r
JOIN Rank_before rb
	ON r.season = rb.season AND r.stage = rb.stage AND opponent = rb.team_name
WHERE r.home_team_name = 'Real Madrid CF' OR r.away_team_name = 'Real Madrid CF'
ORDER BY r.season, r.stage)
GROUP BY manager, group_before