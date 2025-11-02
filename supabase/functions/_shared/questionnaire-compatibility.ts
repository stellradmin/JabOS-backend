/**
 * Questionnaire Compatibility Algorithm
 * Implements the pseudocode specifications exactly
 */

// Constants matching pseudocode specifications
const QUESTIONNAIRE_GROUPS = {
  G1: ["Q1", "Q2", "Q3", "Q4", "Q5"], // Communication, Expectations & Conflict Resolution
  G2: ["Q6", "Q7", "Q8", "Q9", "Q10"], // Emotional Connection, Intimacy & Affection
  G3: ["Q11", "Q12", "Q13", "Q14", "Q15"], // Shared Life, Practicalities & Future Vision
  G4: ["Q16", "Q17", "Q18", "Q19", "Q20"], // Individuality, Boundaries & Personal Beliefs
  G5: ["Q21", "Q22", "Q23", "Q24", "Q25"]  // Relationship Dynamics, Growth & Outlook
};

const LIKERT_MAX_SCORE = 5.0;
const RAW_QUESTION_MAX_SCORE = 4.0; // (LIKERT_MAX_SCORE - 1)

/**
 * Map response strings to numerical values (1-5)
 */
function responseToScore(response: string): number {
  switch (response.toLowerCase()) {
    case "stronglydisagree": return 1;
    case "disagree": return 2;
    case "neutral": return 3;
    case "agree": return 4;
    case "stronglyagree": return 5;
    default: return 3; // Default to neutral if unknown response
  }
}

/**
 * Get letter grade from 0-100 score
 */
function getLetterGrade(score: number): string {
  const normalizedScore = Math.max(0.0, Math.min(score, 100.0));
  if (normalizedScore >= 90.0) return "A";
  else if (normalizedScore >= 80.0) return "B";
  else if (normalizedScore >= 70.0) return "C";
  else if (normalizedScore >= 60.0) return "D";
  else return "F";
}

/**
 * Map question index to group (based on question numbering)
 */
function getQuestionGroup(questionIndex: number): string {
  if (questionIndex <= 4) return "G1"; // Questions 0-4 (Q1-Q5)
  else if (questionIndex <= 9) return "G2"; // Questions 5-9 (Q6-Q10)
  else if (questionIndex <= 14) return "G3"; // Questions 10-14 (Q11-Q15)
  else if (questionIndex <= 19) return "G4"; // Questions 15-19 (Q16-Q20)
  else return "G5"; // Questions 20-24 (Q21-Q25)
}

/**
 * Map group string (G0-G4 from questionnaire data) to pseudocode groups (G1-G5)
 */
function mapQuestionnaireGroupToPseudocode(group: string): string {
  switch (group) {
    case "G0": return "G1";
    case "G1": return "G2";
    case "G2": return "G3";
    case "G3": return "G4";
    case "G4": return "G5";
    default: return group; // Return as-is if already in correct format
  }
}

/**
 * QUESTIONNAIRE COMPATIBILITY CORE FUNCTION
 * Implements the pseudocode algorithm exactly
 */
export function calculateQuestionnaireCompatibility(
  answersA: any[], 
  answersB: any[]
): { groupScores: { [groupID: string]: number }; overallGrade: string } {
  
  const groupRawScores: { [groupID: string]: number } = { G1: 0.0, G2: 0.0, G3: 0.0, G4: 0.0, G5: 0.0 };
  const groupCounts: { [groupID: string]: number } = { G1: 0, G2: 0, G3: 0, G4: 0, G5: 0 };
  const normalizedGroupScores: { [groupID: string]: number } = {};
  
  // Process questionnaire data - handle both array format and question-based format
  const processedAnswersA: { [questionID: string]: number } = {};
  const processedAnswersB: { [questionID: string]: number } = {};
  
  // Convert array format to question ID format
  if (Array.isArray(answersA)) {
    answersA.forEach((item, index) => {
      const questionID = `Q${index + 1}`;
      if (typeof item === 'object' && item.answer) {
        processedAnswersA[questionID] = responseToScore(item.answer);
      } else if (typeof item === 'string') {
        processedAnswersA[questionID] = responseToScore(item);
      } else if (typeof item === 'number') {
        processedAnswersA[questionID] = item;
      }
    });
  }
  
  if (Array.isArray(answersB)) {
    answersB.forEach((item, index) => {
      const questionID = `Q${index + 1}`;
      if (typeof item === 'object' && item.answer) {
        processedAnswersB[questionID] = responseToScore(item.answer);
      } else if (typeof item === 'string') {
        processedAnswersB[questionID] = responseToScore(item);
      } else if (typeof item === 'number') {
        processedAnswersB[questionID] = item;
      }
    });
  }
  
  // Calculate compatibility by groups
  for (const [groupID, questionList] of Object.entries(QUESTIONNAIRE_GROUPS)) {
    for (const questionID of questionList) {
      if (questionID in processedAnswersA && questionID in processedAnswersB) {
        const answerA = processedAnswersA[questionID];
        const answerB = processedAnswersB[questionID];
        
        // Validate answers are in valid range
        if (!(1 <= answerA && answerA <= LIKERT_MAX_SCORE && 1 <= answerB && answerB <= LIKERT_MAX_SCORE)) {
          continue;
        }
        
        // Calculate divergence-based compatibility
        const divergence = Math.abs(answerA - answerB);
        const rawScore = RAW_QUESTION_MAX_SCORE - divergence;
        
        groupRawScores[groupID] += rawScore;
        groupCounts[groupID] += 1;
      }
    }
  }
  
  // Calculate normalized scores for each group
  let overallNormalizedScoreSum = 0.0;
  let numGroupsScored = 0;
  
  for (const groupID of Object.keys(QUESTIONNAIRE_GROUPS)) {
    if (groupCounts[groupID] > 0) {
      const avgRawScore = groupRawScores[groupID] / groupCounts[groupID];
      const normalizedScore = (avgRawScore / RAW_QUESTION_MAX_SCORE) * 100.0;
      normalizedGroupScores[groupID] = normalizedScore;
      overallNormalizedScoreSum += normalizedScore;
      numGroupsScored += 1;
    } else {
      normalizedGroupScores[groupID] = 0.0;
    }
  }
  
  // Calculate overall grade
  let overallNormalizedScore = 0.0;
  if (numGroupsScored > 0) {
    overallNormalizedScore = overallNormalizedScoreSum / numGroupsScored;
  }
  
  const overallGrade = getLetterGrade(overallNormalizedScore);
  
  return { groupScores: normalizedGroupScores, overallGrade };
}

/**
 * Helper function to validate questionnaire data format
 */
export function validateQuestionnaireData(answers: any[]): boolean {
  if (!Array.isArray(answers)) return false;
  if (answers.length !== 25) return false;
  
  return answers.every((item, index) => {
    if (typeof item === 'object' && item.answer) {
      return typeof item.answer === 'string';
    } else if (typeof item === 'string') {
      return true;
    } else if (typeof item === 'number') {
      return item >= 1 && item <= 5;
    }
    return false;
  });
}

/**
 * Convert questionnaire responses to standardized format
 */
export function standardizeQuestionnaireResponses(responses: any[]): { [questionID: string]: number } {
  const standardized: { [questionID: string]: number } = {};
  
  responses.forEach((item, index) => {
    const questionID = `Q${index + 1}`;
    if (typeof item === 'object' && item.answer) {
      standardized[questionID] = responseToScore(item.answer);
    } else if (typeof item === 'string') {
      standardized[questionID] = responseToScore(item);
    } else if (typeof item === 'number') {
      standardized[questionID] = Math.max(1, Math.min(5, item));
    } else {
      standardized[questionID] = 3; // Default to neutral
    }
  });
  
  return standardized;
}