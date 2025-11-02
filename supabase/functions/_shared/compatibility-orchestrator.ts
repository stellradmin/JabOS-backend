/**
 * Compatibility Orchestrator
 * Implements the core matching orchestration from pseudocode specifications
 */

import { calculateAstrologicalCompatibility, NatalChart, BodyObject } from './astronomical-calculations.ts';
import { calculateQuestionnaireCompatibility } from './questionnaire-compatibility.ts';

// Constants matching pseudocode
const MINIMUM_COMPATIBILITY_SCORE_THRESHOLD = 60.0;
const DATE_ACTIVITIES = ["Dinner", "Drinks", "Coffee", "Activity", "Any"];
const ZODIAC_SIGNS = ["Aries", "Taurus", "Gemini", "Cancer", "Leo", "Virgo", 
  "Libra", "Scorpio", "Sagittarius", "Capricorn", "Aquarius", "Pisces", "Any"];

// Data structures matching pseudocode
interface UserPreferences {
  preferredZodiac: string;
  preferredActivity: string;
}

interface UserBirthData {
  dateOfBirth: string;
  placeOfBirth: string;
  timeOfBirth: string;
}

interface UserProfile {
  userID: string;
  name: string;
  preferences: UserPreferences;
  birthData: UserBirthData;
  natalChartData: NatalChart;
  questionnaireAnswers: any[]; // Array format from database
}

interface MatchResult {
  userA_ID: string;
  userB_ID: string;
  eligibleByPreferences: boolean;
  astrologicalScore: number; // 0-100
  astrologicalGrade: string; // A-F or "N/A"
  questionnaireScores: { [groupID: string]: number }; // Group scores 0-100
  questionnaireGrade: string; // A-F or "N/A"
  meetsScoreThreshold: boolean; // True if Astro Score >= 60 OR Quest Grade is D or better
  priorityScore: number; // Numerical score based on grades for ranking
  isMatchRecommended: boolean; // Final decision based on thresholds/logic
}

/**
 * Check preference eligibility between two users
 */
function checkPreferenceEligibility(userA: UserProfile, userB: UserProfile): boolean {
  let sunSignA: string | null = null;
  let sunSignB: string | null = null;
  
  // Get sun signs from natal chart data
  if (userA.natalChartData?.corePlacements?.Sun?.sign) {
    sunSignA = userA.natalChartData.corePlacements.Sun.sign;
  }
  if (userB.natalChartData?.corePlacements?.Sun?.sign) {
    sunSignB = userB.natalChartData.corePlacements.Sun.sign;
  }
  
  if (!sunSignA || !sunSignB) return false; // Cannot check eligibility without Sun signs
  
  const matchZodiacA = (userA.preferences.preferredZodiac === "Any" || userA.preferences.preferredZodiac === sunSignB);
  const matchZodiacB = (userB.preferences.preferredZodiac === "Any" || userB.preferences.preferredZodiac === sunSignA);
  const matchActivityA = (userA.preferences.preferredActivity === "Any" || userA.preferences.preferredActivity === userB.preferences.preferredActivity);
  const matchActivityB = (userB.preferences.preferredActivity === "Any" || userB.preferences.preferredActivity === userA.preferences.preferredActivity);
  
  return (matchZodiacA && matchZodiacB && matchActivityA && matchActivityB);
}

/**
 * Calculate match priority score for ranking (higher is better)
 */
function calculateMatchPriorityScore(astroGrade: string, questGrade: string): number {
  const gradeValues: { [grade: string]: number } = { "A": 4.0, "B": 3.0, "C": 2.0, "D": 1.0, "F": 0.0, "N/A": -1.0 };
  
  const astroValue = gradeValues[astroGrade] ?? -1.0;
  const questValue = gradeValues[questGrade] ?? -1.0;
  
  // Simple sum - could be weighted if one score is more important
  return astroValue + questValue;
}

/**
 * Determine final match recommendation
 */
function determineMatchRecommendation(matchInfo: MatchResult): boolean {
  // Must be eligible by preferences AND meet the score threshold
  if (!matchInfo.eligibleByPreferences || !matchInfo.meetsScoreThreshold) {
    return false;
  }
  
  // Optional additional logic can be added here
  // For now, basic logic: eligible + threshold = recommended
  return true;
}

/**
 * MAIN ORCHESTRATION FUNCTION
 * Find potential matches for a given user (implements pseudocode exactly)
 */
export function findPotentialMatches(targetUser: UserProfile, candidatePool: UserProfile[]): MatchResult[] {
  const potentialMatches: MatchResult[] = [];
  
  // Iterate through all candidate users
  for (const candidateUser of candidatePool) {
    // Skip self-matching
    if (targetUser.userID === candidateUser.userID) {
      continue;
    }
    
    // Step 1: Initial Filtering (Rule 1)
    // Check if both users have the necessary data for filtering
    if (!targetUser.preferences || !candidateUser.preferences || 
        !targetUser.natalChartData || !candidateUser.natalChartData) {
      // Handle missing data: skip user with essential missing data
      continue;
    }
    
    const eligible = checkPreferenceEligibility(targetUser, candidateUser);
    
    // Initialize MatchResult with defaults
    let astroScore = 0.0;
    let astroGrade = "N/A";
    let questScores: { [groupID: string]: number } = {};
    let questGrade = "N/A";
    let meetsThreshold = false;
    let priorityScore = 0.0;
    
    // If eligible by preferences, calculate compatibility
    if (eligible) {
      // Step 2: Calculate Astrological Compatibility (Rule 2)
      if (targetUser.natalChartData && candidateUser.natalChartData) {
        const astroResult = calculateAstrologicalCompatibility(targetUser.natalChartData, candidateUser.natalChartData);
        astroScore = astroResult.score;
        astroGrade = astroResult.grade;
      }
      
      // Step 3: Calculate Questionnaire Compatibility (Rule 3)
      if (targetUser.questionnaireAnswers && candidateUser.questionnaireAnswers) {
        const questResult = calculateQuestionnaireCompatibility(targetUser.questionnaireAnswers, candidateUser.questionnaireAnswers);
        questScores = questResult.groupScores;
        questGrade = questResult.overallGrade;
      }
      
      // Step 3.5: Check Minimum Score Threshold
      const astroMeets = (astroScore >= MINIMUM_COMPATIBILITY_SCORE_THRESHOLD);
      const questMeets = (!["F", "N/A"].includes(questGrade) && questGrade !== null); // Grades D, C, B, A imply score >= 60
      meetsThreshold = (astroMeets || questMeets);
      
      // Step 3.6: Calculate Priority Score for Ranking
      priorityScore = calculateMatchPriorityScore(astroGrade, questGrade);
    }
    
    // Create MatchResult Object
    const matchInfo: MatchResult = {
      userA_ID: targetUser.userID,
      userB_ID: candidateUser.userID,
      eligibleByPreferences: eligible,
      astrologicalScore: astroScore,
      astrologicalGrade: astroGrade,
      questionnaireScores: questScores,
      questionnaireGrade: questGrade,
      meetsScoreThreshold: meetsThreshold,
      priorityScore: priorityScore,
      isMatchRecommended: false // Will be determined next
    };
    
    // Add result (even ineligible ones, might be useful for analytics)
    potentialMatches.push(matchInfo);
  }
  
  // Step 4: Determine Final Match Recommendation for all potential matches
  for (const matchInfo of potentialMatches) {
    matchInfo.isMatchRecommended = determineMatchRecommendation(matchInfo);
  }
  
  // Step 5: Sort Matches by Priority (descending order)
  potentialMatches.sort((a, b) => b.priorityScore - a.priorityScore);
  
  return potentialMatches;
}

/**
 * Calculate compatibility between two specific users
 */
export function calculateUserCompatibility(userA: UserProfile, userB: UserProfile): MatchResult {
  const matches = findPotentialMatches(userA, [userB]);
  return matches.length > 0 ? matches[0] : {
    userA_ID: userA.userID,
    userB_ID: userB.userID,
    eligibleByPreferences: false,
    astrologicalScore: 0.0,
    astrologicalGrade: "N/A",
    questionnaireScores: {},
    questionnaireGrade: "N/A",
    meetsScoreThreshold: false,
    priorityScore: 0.0,
    isMatchRecommended: false
  };
}

/**
 * Helper function to create UserProfile from database data
 * Handles both legacy and v2.0 natal chart formats
 */
export function createUserProfileFromDbData(userData: any): UserProfile {
  // Handle natal chart data - convert from v2.0 format if needed
  let natalChartData = null;
  if (userData.natal_chart_data) {
    // Check if it's the new v2.0 format
    if (userData.natal_chart_data.corePlacements && userData.natal_chart_data.houses) {
      // Already in correct format
      natalChartData = userData.natal_chart_data;
    } else if (userData.natal_chart_data.version === '2.0') {
      // Explicitly marked as v2.0
      natalChartData = userData.natal_chart_data;
    } else {
      // Legacy format - needs conversion
      natalChartData = convertLegacyNatalChart(userData.natal_chart_data, userData.id);
    }
  }

  return {
    userID: userData.id,
    name: userData.display_name || userData.name || '',
    preferences: {
      preferredZodiac: userData.preferences?.preferredZodiac || userData.preferences?.zodiac || "Any",
      preferredActivity: userData.preferences?.preferredActivity || userData.preferences?.activity || "Any"
    },
    birthData: {
      dateOfBirth: userData.birth_date || '',
      placeOfBirth: userData.birth_location || '',
      timeOfBirth: userData.birth_time || ''
    },
    natalChartData: natalChartData,
    questionnaireAnswers: userData.questionnaire_responses || []
  };
}

/**
 * Convert legacy natal chart format to v2.0 format
 */
function convertLegacyNatalChart(oldChart: any, userId: string): NatalChart {
  if (!oldChart) return null;

  const corePlacements: { [key: string]: BodyObject } = {};
  const houses: { [key: string]: string } = {};

  // Convert planetary bodies
  const bodyMappings = {
    'sun': 'Sun',
    'moon': 'Moon',
    'mercury': 'Mercury',
    'venus': 'Venus',
    'mars': 'Mars',
    'jupiter': 'Jupiter',
    'saturn': 'Saturn',
    'uranus': 'Uranus',
    'neptune': 'Neptune',
    'pluto': 'Pluto',
    'ascendant': 'Ascendant'
  };

  for (const [oldKey, newKey] of Object.entries(bodyMappings)) {
    if (oldChart[oldKey]) {
      const body = oldChart[oldKey];
      corePlacements[newKey] = {
        name: newKey,
        sign: body.sign,
        degree: body.degree,
        absoluteDegree: calculateAbsoluteDegree(body.sign, body.degree)
      };
    } else if (oldChart[newKey]) {
      // Already capitalized
      const body = oldChart[newKey];
      corePlacements[newKey] = {
        name: newKey,
        sign: body.sign,
        degree: body.degree,
        absoluteDegree: body.absoluteDegree || calculateAbsoluteDegree(body.sign, body.degree)
      };
    }
  }

  // Generate houses if not present (using whole sign houses based on Ascendant)
  if (oldChart.houses) {
    // Use existing houses if available
    if (Array.isArray(oldChart.houses)) {
      // Convert array format to object format
      oldChart.houses.forEach((house: any) => {
        houses[`H${house.house}`] = house.sign;
      });
    } else if (typeof oldChart.houses === 'object') {
      // Already in object format
      Object.assign(houses, oldChart.houses);
    }
  } else {
    // Generate houses based on Ascendant
    const ascendantSign = corePlacements['Ascendant']?.sign || 'Aries';
    const signs = ['Aries', 'Taurus', 'Gemini', 'Cancer', 'Leo', 'Virgo',
                   'Libra', 'Scorpio', 'Sagittarius', 'Capricorn', 'Aquarius', 'Pisces'];
    const startIndex = signs.indexOf(ascendantSign);
    
    for (let i = 0; i < 12; i++) {
      const signIndex = (startIndex + i) % 12;
      houses[`H${i + 1}`] = signs[signIndex];
    }
  }

  return {
    userID: userId,
    corePlacements,
    houses
  };
}

/**
 * Calculate absolute degree from sign and degree within sign
 */
function calculateAbsoluteDegree(sign: string, degree: number): number {
  const signOffsets: { [key: string]: number } = {
    'Aries': 0, 'Taurus': 30, 'Gemini': 60, 'Cancer': 90,
    'Leo': 120, 'Virgo': 150, 'Libra': 180, 'Scorpio': 210,
    'Sagittarius': 240, 'Capricorn': 270, 'Aquarius': 300, 'Pisces': 330
  };
  
  const offset = signOffsets[sign] || 0;
  return offset + degree;
}

/**
 * Calculate combined compatibility score with weighted averaging
 * 40% Astrological + 60% Questionnaire (as specified in original requirements)
 */
export function calculateCombinedScore(astroScore: number, questScore: number): number {
  return (astroScore * 0.4) + (questScore * 0.6);
}

/**
 * Convert grade to numerical score for combined calculations
 */
export function gradeToScore(grade: string): number {
  switch (grade) {
    case "A": return 95;
    case "B": return 85;
    case "C": return 75;
    case "D": return 65;
    case "F": return 45;
    default: return 50; // N/A or unknown
  }
}

// Export types for use in other modules
export type { UserProfile, MatchResult, UserPreferences, UserBirthData };